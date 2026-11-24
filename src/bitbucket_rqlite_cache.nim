## Synchronizes Bitbucket repository and branch metadata into rqlite.

import std/[atomics, base64, httpclient, json, os, strformat, strutils, times]
import posixglob

const
  TimeoutMs = 30_000
  WatchdogExitCode* = 3
  DefaultBitbucketApiBase = "https://api.bitbucket.org/2.0/repositories"

type
  Config* = object
    workspace*: string
    repoPatterns*: seq[string]
    bitbucketApiUrl*: string
    rqliteUrl*: string
    sleepSeconds*: int
    rqliteAuth*: string
    rateLimitSleepSeconds*: int
    watchdogSeconds*: int
    once*: bool

  RqliteError* = object of CatchableError

var lastProgress: Atomic[int64]

proc markProgress*() =
  ## Records that the daemon is still making progress; the watchdog reads it.
  lastProgress.store(getTime().toUnix)

proc usage() =
  echo """
Usage:
  bitbucket-rqlite-cache [--once]

Required environment variables:
  BITBUCKET_WORKSPACE                 Bitbucket workspace, required
  BITBUCKET_USER                      Bitbucket username or email, required
  BITBUCKET_TOKEN                     Bitbucket app password, required
  RQLITE_URL                          rqlite URL, required

Optional environment variables:
  BITBUCKET_REPO_PATTERNS             Comma-separated repository glob patterns, default: empty string
  BITBUCKET_API_URL                   Bitbucket repositories API URL, default: https://api.bitbucket.org/2.0/repositories
  SYNC_SLEEP_SECONDS                  Sleep between repositories, default: 1
  BITBUCKET_RATE_LIMIT_SLEEP_SECONDS  Sleep after Bitbucket HTTP 429, default: 60
  WATCHDOG_SECONDS                    Exit with code 3 when nothing progresses for this long, 0 disables, default: 600
  RQLITE_USER                         rqlite username, default: empty string
  RQLITE_PASSWORD                     rqlite password, default: empty string

Options:
  --once  Run one update cycle and exit
  --help  Show this help

Examples:
  BITBUCKET_WORKSPACE=test RQLITE_URL=http://rqlite:4001 ./bitbucket-rqlite-cache
  BITBUCKET_REPO_PATTERNS='api-*,ops-*' ./bitbucket-rqlite-cache
  ./bitbucket-rqlite-cache --once
  BITBUCKET_RATE_LIMIT_SLEEP_SECONDS=120 ./bitbucket-rqlite-cache
"""
  quit(0)

proc die(msg: string) =
  stderr.writeLine("ERROR: " & msg)
  quit(1)

proc requiredEnv(name: string): string =
  result = getEnv(name)
  if result.len == 0:
    die(name & " is not set")

proc parseIntValue*(name, value: string, defaultValue: int): int =
  if value.len == 0:
    return defaultValue

  try:
    result = parseInt(value)
  except ValueError:
    die(name & " must be an integer")

proc intEnv(name: string, defaultValue: int): int =
  parseIntValue(name, getEnv(name), defaultValue)

proc parseRepoPatterns*(value: string): seq[string] =
  parseGlobPatterns(value)

proc repoMatchesPatterns*(repo: string, patterns: seq[string]): bool =
  if patterns.len == 0:
    return true

  globMatchAny(patterns, repo)

proc nowUtc(): string =
  getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc basicAuthHeader*(user, password: string): string =
  "Basic " & encode(user & ":" & password)

proc normalizedUrl*(url: string): string =
  result = url
  while result.endsWith("/"):
    result.setLen(result.len - 1)

proc newJsonClient(): HttpClient =
  result = newHttpClient(timeout = TimeoutMs)
  result.headers = newHttpHeaders({
    "Accept": "application/json",
    "Content-Type": "application/json"
  })

proc rqliteAuthHeader(): string =
  let user = getEnv("RQLITE_USER")
  let password = getEnv("RQLITE_PASSWORD")

  if user.len == 0:
    return ""

  basicAuthHeader(user, password)

proc bitbucketAuthHeader(): string =
  let user = getEnv("BITBUCKET_USER")
  let token = getEnv("BITBUCKET_TOKEN")

  if user.len == 0:
    die("BITBUCKET_USER is not set")
  if token.len == 0:
    die("BITBUCKET_TOKEN is not set")

  basicAuthHeader(user, token)

proc jsonStr*(node: JsonNode, key: string, defaultValue = ""): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind != JNull:
    return node[key].getStr(defaultValue)
  defaultValue

proc newRqliteClient(cfg: Config): HttpClient =
  ## One connection per request: an idle keep-alive connection can be closed
  ## by a proxy in front of rqlite (an ingress) while Bitbucket is slow.
  result = newJsonClient()
  result.headers["Connection"] = "close"
  if cfg.rqliteAuth.len > 0:
    result.headers["Authorization"] = cfg.rqliteAuth

proc rqliteError*(responseBody: string): string =
  ## Returns the first error in an rqlite /db/execute response, or "".
  let data = parseJson(responseBody)

  if data.kind == JObject and data.hasKey("error"):
    return data["error"].getStr

  if data.kind == JObject and data.hasKey("results"):
    for item in data["results"]:
      if item.kind == JObject and item.hasKey("error"):
        return item["error"].getStr

  ""

proc rqliteExecute(
  cfg: Config,
  statements: seq[JsonNode],
  raiseOnError: bool = true
): bool =
  ## Raises RqliteError (or a transport error) when raiseOnError is true,
  ## otherwise returns false on any failure.
  var body = newJArray()
  for stmt in statements:
    body.add(stmt)

  try:
    let client = newRqliteClient(cfg)
    defer: client.close()

    let response = client.request(
      normalizedUrl(cfg.rqliteUrl) & "/db/execute",
      httpMethod = HttpPost,
      body = $body
    )
    markProgress()

    if response.code != Http200:
      raise newException(
        RqliteError,
        "rqlite HTTP error: " & $response.code & " " & response.body
      )

    let error = rqliteError(response.body)
    if error.len > 0:
      raise newException(RqliteError, "rqlite error: " & error)

  except CatchableError:
    if raiseOnError:
      raise
    return false

  true

proc rqliteExecuteOne(
  cfg: Config,
  statement: JsonNode,
  raiseOnError: bool = true
): bool =
  rqliteExecute(cfg, @[statement], raiseOnError)

proc initDb(cfg: Config) =
  discard rqliteExecuteOne(cfg, %"""
CREATE TABLE IF NOT EXISTS repos (
    workspace  TEXT NOT NULL,
    repo       TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_error TEXT,
    PRIMARY KEY (workspace, repo)
)
""")

  discard rqliteExecuteOne(cfg, %"""
CREATE TABLE IF NOT EXISTS repo_branches (
    workspace    TEXT NOT NULL,
    repo         TEXT NOT NULL,
    branch       TEXT NOT NULL,
    commit_hash  TEXT NOT NULL,
    commit_hash7 TEXT NOT NULL,
    commit_date  TEXT,
    updated_at   TEXT NOT NULL,
    PRIMARY KEY (workspace, repo, branch)
)
""")

  # Best-effort migration for older databases created before last_error existed.
  discard rqliteExecuteOne(
    cfg,
    %"ALTER TABLE repos ADD COLUMN last_error TEXT",
    raiseOnError = false
  )

proc buildSaveRepoStmt(cfg: Config, repo, marker: string): JsonNode =
  %*[
    """
INSERT INTO repos (workspace, repo, updated_at, last_error)
VALUES (?, ?, ?, NULL)
ON CONFLICT(workspace, repo)
DO UPDATE SET
    updated_at = excluded.updated_at,
    last_error = NULL
""",
    cfg.workspace,
    repo,
    marker
  ]

proc buildRepoErrorStmt(cfg: Config, repo, errorMsg: string): JsonNode =
  %*[
    """
INSERT INTO repos (workspace, repo, updated_at, last_error)
VALUES (?, ?, ?, ?)
ON CONFLICT(workspace, repo)
DO UPDATE SET
    last_error = excluded.last_error
""",
    cfg.workspace,
    repo,
    nowUtc(),
    errorMsg
  ]

proc buildSaveBranchStmt*(
  cfg: Config,
  repo, branch, commitHash, commitDate, marker: string
): JsonNode =
  let commitHash7 =
    if commitHash.len >= 7: commitHash[0 .. 6]
    else: commitHash

  %*[
    """
INSERT INTO repo_branches (
    workspace,
    repo,
    branch,
    commit_hash,
    commit_hash7,
    commit_date,
    updated_at
)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(workspace, repo, branch)
DO UPDATE SET
    commit_hash = excluded.commit_hash,
    commit_hash7 = excluded.commit_hash7,
    commit_date = excluded.commit_date,
    updated_at = excluded.updated_at
""",
    cfg.workspace,
    repo,
    branch,
    commitHash,
    commitHash7,
    commitDate,
    marker
  ]

proc deleteStaleRepos(cfg: Config, marker: string) =
  discard rqliteExecuteOne(cfg, %*[
    """
DELETE FROM repos
WHERE workspace = ?
  AND updated_at < ?
""",
    cfg.workspace,
    marker
  ])

proc deleteStaleBranchesForRepo(cfg: Config, repo, marker: string) =
  discard rqliteExecuteOne(cfg, %*[
    """
DELETE FROM repo_branches
WHERE workspace = ?
  AND repo = ?
  AND updated_at < ?
""",
    cfg.workspace,
    repo,
    marker
  ])

proc watchdogConfigError*(cfg: Config): string =
  ## The watchdog must outlast the longest planned sleep, or it kills a
  ## healthy daemon. Returns "" when the setting is valid.
  if cfg.watchdogSeconds < 0:
    return "WATCHDOG_SECONDS must be 0 or more"
  if cfg.watchdogSeconds == 0:
    return ""

  let longestSleep = max(cfg.sleepSeconds, cfg.rateLimitSleepSeconds)
  if cfg.watchdogSeconds <= longestSleep:
    return &"WATCHDOG_SECONDS ({cfg.watchdogSeconds}) must be greater than " &
      &"SYNC_SLEEP_SECONDS and BITBUCKET_RATE_LIMIT_SLEEP_SECONDS ({longestSleep})"
  ""

proc parseConfig(): Config =
  let args = commandLineParams()
  var once = false

  if args.len > 0:
    if args.len == 1 and args[0] in ["--help", "-h", "help"]:
      usage()

    for arg in args:
      case arg
      of "--once":
        once = true
      else:
        die("Command line option " & arg & " is not supported; use environment variables")

  result = Config(
    workspace: requiredEnv("BITBUCKET_WORKSPACE"),
    repoPatterns: parseRepoPatterns(getEnv("BITBUCKET_REPO_PATTERNS")),
    bitbucketApiUrl: normalizedUrl(getEnv("BITBUCKET_API_URL", DefaultBitbucketApiBase)),
    rqliteUrl: requiredEnv("RQLITE_URL"),
    rqliteAuth: rqliteAuthHeader(),
    sleepSeconds: intEnv("SYNC_SLEEP_SECONDS", 1),
    rateLimitSleepSeconds: intEnv("BITBUCKET_RATE_LIMIT_SLEEP_SECONDS", 60),
    watchdogSeconds: intEnv("WATCHDOG_SECONDS", 600),
    once: once
  )

  let error = watchdogConfigError(result)
  if error.len > 0:
    die(error)

proc bitbucketGet(client: HttpClient, url: string): Response =
  ## A kept-alive connection may have been closed by the other side while we
  ## slept; drop it and try once more on a new connection.
  try:
    result = client.request(url, httpMethod = HttpGet)
  except CatchableError as e:
    stderr.writeLine(&"Bitbucket request failed ({e.msg}), retrying on a new connection")
    client.close()
    result = client.request(url, httpMethod = HttpGet)
  markProgress()

proc bitbucketRequest(
  client: HttpClient,
  cfg: Config,
  url: string
): Response =
  let response = bitbucketGet(client, url)

  if response.code == Http429:
    stderr.writeLine(&"Bitbucket rate limit: sleeping {cfg.rateLimitSleepSeconds} seconds")
    sleep(cfg.rateLimitSleepSeconds * 1000)
    markProgress()
    return bitbucketGet(client, url)

  response

proc bitbucketGetJson(
  client: HttpClient,
  cfg: Config,
  url: string
): JsonNode =
  let response = bitbucketRequest(client, cfg, url)

  if response.code != Http200:
    raise newException(
      CatchableError,
      "Bitbucket HTTP error: " & $response.code & " " & response.body
    )

  parseJson(response.body)

proc iterRepos(client: HttpClient, cfg: Config): seq[string] =
  var url = &"{cfg.bitbucketApiUrl}/{cfg.workspace}/?pagelen=100&fields=values.slug,next"

  while url.len > 0:
    let data = bitbucketGetJson(client, cfg, url)

    if data.kind == JObject and data.hasKey("values"):
      for item in data["values"]:
        let repo = jsonStr(item, "slug")
        if repoMatchesPatterns(repo, cfg.repoPatterns):
          result.add(repo)

    url = jsonStr(data, "next")

proc collectBranchStatements(
  client: HttpClient,
  cfg: Config,
  repo, marker: string
): seq[JsonNode] =
  var url =
    &"{cfg.bitbucketApiUrl}/{cfg.workspace}/{repo}/refs/branches" &
    "?pagelen=100" &
    "&fields=values.name,values.target.hash,values.target.date,next"

  while url.len > 0:
    let response = bitbucketRequest(client, cfg, url)

    if response.code in {Http403, Http404}:
      return result

    if response.code != Http200:
      raise newException(
        CatchableError,
        "Bitbucket HTTP error: " & $response.code & " " & response.body
      )

    let data = parseJson(response.body)

    if data.kind == JObject and data.hasKey("values"):
      for item in data["values"]:
        let branch = jsonStr(item, "name")
        if branch.len == 0:
          continue

        if not item.hasKey("target") or item["target"].kind != JObject:
          continue

        let target = item["target"]
        let commitHash = jsonStr(target, "hash")
        let commitDate = jsonStr(target, "date")

        if commitHash.len == 0:
          continue

        result.add(buildSaveBranchStmt(cfg, repo, branch, commitHash, commitDate, marker))

    url = jsonStr(data, "next")

proc saveReposBatch(
  cfg: Config,
  repos: seq[string],
  marker: string
) =
  var statements: seq[JsonNode] = @[]

  for repo in repos:
    statements.add(buildSaveRepoStmt(cfg, repo, marker))

  if statements.len > 0:
    discard rqliteExecute(cfg, statements)

proc updateOnce(bitbucketClient: HttpClient, cfg: Config) =
  let cycleStartedAt = nowUtc()
  let startedMono = epochTime()

  echo &"Starting update cycle at {cycleStartedAt}"

  let repos = iterRepos(bitbucketClient, cfg)
  echo &"Found {repos.len} repositories"

  saveReposBatch(cfg, repos, cycleStartedAt)

  for repo in repos:
    let repoMarker = nowUtc()

    try:
      let branchStatements = collectBranchStatements(bitbucketClient, cfg, repo, repoMarker)

      if branchStatements.len > 0:
        discard rqliteExecute(cfg, branchStatements)

      deleteStaleBranchesForRepo(cfg, repo, repoMarker)

      echo &"{repo}: saved {branchStatements.len} branches"

    except CatchableError as e:
      stderr.writeLine(&"ERROR: {repo}: {e.msg}")
      discard rqliteExecuteOne(cfg, buildRepoErrorStmt(cfg, repo, e.msg), raiseOnError = false)

    sleep(cfg.sleepSeconds * 1000)
    markProgress()

  deleteStaleRepos(cfg, cycleStartedAt)

  let elapsed = epochTime() - startedMono
  echo &"Finished update cycle in {elapsed:.1f} seconds"

proc watchdog(limitSeconds: int) {.thread.} =
  ## A blocked socket call has no timeout of its own (a send to a peer that
  ## vanished, a connect); exit so that the container is restarted.
  while true:
    sleep(1000)
    let idle = getTime().toUnix - lastProgress.load
    if idle >= limitSeconds:
      stderr.writeLine(&"ERROR: watchdog: no progress for {idle} seconds, exiting")
      quit(WatchdogExitCode)

proc main() =
  let cfg = parseConfig()

  markProgress()
  var watchdogThread: Thread[int]
  if cfg.watchdogSeconds > 0:
    createThread(watchdogThread, watchdog, cfg.watchdogSeconds)

  let bitbucketClient = newJsonClient()
  defer: bitbucketClient.close()
  bitbucketClient.headers["Authorization"] = bitbucketAuthHeader()

  var dbReady = false

  while true:
    try:
      if not dbReady:
        initDb(cfg)
        dbReady = true
      updateOnce(bitbucketClient, cfg)
    except CatchableError as e:
      stderr.writeLine(&"ERROR: update cycle failed: {e.msg}")
      if cfg.once:
        quit(1)
      sleep(cfg.rateLimitSleepSeconds * 1000)
      markProgress()

    if cfg.once:
      break

when isMainModule:
  main()
