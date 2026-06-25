import std/[base64, httpclient, json, os, parseopt, strformat, strutils, times]

const
  TimeoutMs = 30_000
  BitbucketApiBase = "https://api.bitbucket.org/2.0/repositories"

type
  Config = object
    workspace: string
    repoPrefix: string
    rqliteUrl: string
    sleepSeconds: int
    rateLimitSleepSeconds: int
    once: bool

proc usage() =
  echo """
Usage:
  bitbucket_rqlite_cache [options]

Options:
  --workspace NAME             Bitbucket workspace, default: empty string
  --repo-prefix PREFIX         Repository prefix filter, default: empty string
  --rqlite-url URL             rqlite URL, default: http://127.0.0.1:4001
  --sleep SECONDS              Sleep between repositories, default: 1
  --rate-limit-sleep SECONDS   Sleep after Bitbucket HTTP 429, default: 60
  --once                       Run one update cycle and exit
  --help                       Show this help

Environment:
  export BITBUCKET_USER='user@example.com'
  export BITBUCKET_TOKEN='bitbucket-app-password'

  export RQLITE_USER='admin'
  export RQLITE_PASSWORD='secret'

Examples:
  ./bitbucket_rqlite_cache --once
  ./bitbucket_rqlite_cache --repo-prefix ''
  ./bitbucket_rqlite_cache --repo-prefix sl-
  ./bitbucket_rqlite_cache --rate-limit-sleep 120
"""
  quit(0)

proc die(msg: string) =
  stderr.writeLine("ERROR: " & msg)
  quit(1)

proc nowUtc(): string =
  getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc basicAuthHeader(user, password: string): string =
  "Basic " & encode(user & ":" & password)

proc normalizedUrl(url: string): string =
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

proc jsonStr(node: JsonNode, key: string, defaultValue = ""): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind != JNull:
    return node[key].getStr(defaultValue)
  defaultValue

proc rqliteExecute(
  client: HttpClient,
  cfg: Config,
  statements: seq[JsonNode],
  fatal: bool = true
): bool =
  var body = newJArray()
  for stmt in statements:
    body.add(stmt)

  let response = client.request(
    normalizedUrl(cfg.rqliteUrl) & "/db/execute",
    httpMethod = HttpPost,
    body = $body
  )

  if response.code != Http200:
    if fatal:
      die("rqlite HTTP error: " & $response.code & " " & response.body)
    return false

  let data = parseJson(response.body)

  if data.kind == JObject and data.hasKey("error"):
    if fatal:
      die(data["error"].getStr)
    return false

  if data.kind == JObject and data.hasKey("results"):
    for item in data["results"]:
      if item.kind == JObject and item.hasKey("error"):
        if fatal:
          die(item["error"].getStr)
        return false

  true

proc rqliteExecuteOne(
  client: HttpClient,
  cfg: Config,
  statement: JsonNode,
  fatal: bool = true
): bool =
  rqliteExecute(client, cfg, @[statement], fatal)

proc initDb(client: HttpClient, cfg: Config) =
  discard rqliteExecuteOne(client, cfg, %"""
CREATE TABLE IF NOT EXISTS repos (
    workspace  TEXT NOT NULL,
    repo       TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_error TEXT,
    PRIMARY KEY (workspace, repo)
)
""")

  discard rqliteExecuteOne(client, cfg, %"""
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
    client,
    cfg,
    %"ALTER TABLE repos ADD COLUMN last_error TEXT",
    fatal = false
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

proc buildSaveBranchStmt(
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

proc deleteStaleRepos(client: HttpClient, cfg: Config, marker: string) =
  discard rqliteExecuteOne(client, cfg, %*[
    """
DELETE FROM repos
WHERE workspace = ?
  AND updated_at < ?
""",
    cfg.workspace,
    marker
  ])

proc deleteStaleBranchesForRepo(
  client: HttpClient,
  cfg: Config,
  repo, marker: string
) =
  discard rqliteExecuteOne(client, cfg, %*[
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

proc parseConfig(): Config =
  result = Config(
    workspace: "",
    repoPrefix: "",
    rqliteUrl: "http://127.0.0.1:4001",
    sleepSeconds: 1,
    rateLimitSleepSeconds: 60,
    once: false
  )

  var parser = initOptParser(commandLineParams())

  for kind, key, value in parser.getopt():
    case kind
    of cmdLongOption:
      case key
      of "workspace":
        result.workspace = value
      of "repo-prefix":
        result.repoPrefix = value
      of "rqlite-url":
        result.rqliteUrl = value
      of "sleep":
        result.sleepSeconds = parseInt(value)
      of "rate-limit-sleep":
        result.rateLimitSleepSeconds = parseInt(value)
      of "once":
        result.once = true
      of "help":
        usage()
      else:
        die("Unknown option: --" & key)
    of cmdShortOption:
      die("Short options are not supported: -" & key)
    of cmdArgument:
      die("Unexpected argument: " & key)
    of cmdEnd:
      discard

proc bitbucketRequest(
  client: HttpClient,
  cfg: Config,
  url: string
): Response =
  let response = client.request(url, httpMethod = HttpGet)

  if response.code == Http429:
    stderr.writeLine(&"Bitbucket rate limit: sleeping {cfg.rateLimitSleepSeconds} seconds")
    sleep(cfg.rateLimitSleepSeconds * 1000)
    return client.request(url, httpMethod = HttpGet)

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
  var url = &"{BitbucketApiBase}/{cfg.workspace}/?pagelen=100&fields=values.slug,next"

  while url.len > 0:
    let data = bitbucketGetJson(client, cfg, url)

    if data.kind == JObject and data.hasKey("values"):
      for item in data["values"]:
        let repo = jsonStr(item, "slug")
        if repo.startsWith(cfg.repoPrefix):
          result.add(repo)

    url = jsonStr(data, "next")

proc collectBranchStatements(
  client: HttpClient,
  cfg: Config,
  repo, marker: string
): seq[JsonNode] =
  var url =
    &"{BitbucketApiBase}/{cfg.workspace}/{repo}/refs/branches" &
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
  rqliteClient: HttpClient,
  cfg: Config,
  repos: seq[string],
  marker: string
) =
  var statements: seq[JsonNode] = @[]

  for repo in repos:
    statements.add(buildSaveRepoStmt(cfg, repo, marker))

  if statements.len > 0:
    discard rqliteExecute(rqliteClient, cfg, statements)

proc updateOnce(
  bitbucketClient: HttpClient,
  rqliteClient: HttpClient,
  cfg: Config
) =
  let cycleStartedAt = nowUtc()
  let startedMono = epochTime()

  echo &"Starting update cycle at {cycleStartedAt}"

  let repos = iterRepos(bitbucketClient, cfg)
  echo &"Found {repos.len} repositories"

  saveReposBatch(rqliteClient, cfg, repos, cycleStartedAt)

  for repo in repos:
    let repoMarker = nowUtc()

    try:
      let branchStatements = collectBranchStatements(bitbucketClient, cfg, repo, repoMarker)

      if branchStatements.len > 0:
        discard rqliteExecute(rqliteClient, cfg, branchStatements)

      deleteStaleBranchesForRepo(rqliteClient, cfg, repo, repoMarker)

      echo &"{repo}: saved {branchStatements.len} branches"

    except CatchableError as e:
      stderr.writeLine(&"ERROR: {repo}: {e.msg}")
      discard rqliteExecuteOne(rqliteClient, cfg, buildRepoErrorStmt(cfg, repo, e.msg), fatal = false)

    sleep(cfg.sleepSeconds * 1000)

  deleteStaleRepos(rqliteClient, cfg, cycleStartedAt)

  let elapsed = epochTime() - startedMono
  echo &"Finished update cycle in {elapsed:.1f} seconds"

proc main() =
  let cfg = parseConfig()

  let bitbucketClient = newJsonClient()
  defer: bitbucketClient.close()
  bitbucketClient.headers["Authorization"] = bitbucketAuthHeader()

  let rqliteClient = newJsonClient()
  defer: rqliteClient.close()

  let rqAuth = rqliteAuthHeader()
  if rqAuth.len > 0:
    rqliteClient.headers["Authorization"] = rqAuth

  initDb(rqliteClient, cfg)

  while true:
    updateOnce(bitbucketClient, rqliteClient, cfg)

    if cfg.once:
      break

when isMainModule:
  main()