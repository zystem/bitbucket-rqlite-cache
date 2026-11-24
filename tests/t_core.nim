import std/[json, unittest]

import ../src/bitbucket_rqlite_cache

suite "configuration parsing helpers":
  test "parses integer values":
    check parseIntValue("SYNC_SLEEP_SECONDS", "", 3) == 3
    check parseIntValue("SYNC_SLEEP_SECONDS", "42", 3) == 42

  test "parses comma-separated repository glob patterns":
    check parseRepoPatterns("") == newSeq[string]()
    check parseRepoPatterns("dev-*, ops-*, ,repo-?") == @["dev-*", "ops-*", "repo-?"]

  test "matches repositories with POSIX glob patterns":
    check repoMatchesPatterns("dev-api", newSeq[string]())
    check repoMatchesPatterns("dev-api", @["dev-*"])
    check repoMatchesPatterns("ops-tool", @["dev-*", "ops-*"])
    check repoMatchesPatterns("repo-a", @["repo-[ab]"])
    check repoMatchesPatterns("repo-x", @["repo-[!ab]"])
    check not repoMatchesPatterns("prod-api", @["dev-*", "ops-*"])
    check not repoMatchesPatterns("repo-aa", @["repo-?"])

suite "HTTP helpers":
  test "builds basic auth header":
    check basicAuthHeader("user", "token") == "Basic dXNlcjp0b2tlbg=="

  test "normalizes trailing slashes":
    check normalizedUrl("http://127.0.0.1:4001///") == "http://127.0.0.1:4001"
    check normalizedUrl("http://127.0.0.1:4001") == "http://127.0.0.1:4001"

suite "json helpers":
  test "reads strings with defaults":
    let node = parseJson("""{"name":"main","empty":null}""")
    check jsonStr(node, "name") == "main"
    check jsonStr(node, "empty", "fallback") == "fallback"
    check jsonStr(node, "missing", "fallback") == "fallback"

suite "rqlite statements":
  test "stores full and short commit hashes":
    let cfg = Config(workspace: "test")
    let stmt = buildSaveBranchStmt(
      cfg,
      "repo-a",
      "main",
      "abcdef123456",
      "2026-07-01T00:00:00Z",
      "2026-07-01T01:00:00Z"
    )

    check stmt.kind == JArray
    check stmt[1].getStr == "test"
    check stmt[2].getStr == "repo-a"
    check stmt[3].getStr == "main"
    check stmt[4].getStr == "abcdef123456"
    check stmt[5].getStr == "abcdef1"

suite "rqlite responses":
  test "finds the first error":
    check rqliteError("""{"results":[{},{}]}""") == ""
    check rqliteError("""{"results":[{},{"error":"no such table: x"}]}""") == "no such table: x"
    check rqliteError("""{"error":"not leader"}""") == "not leader"

suite "watchdog setting":
  test "accepts 0 and values above the longest sleep":
    check watchdogConfigError(Config(watchdogSeconds: 0, rateLimitSleepSeconds: 60)) == ""
    check watchdogConfigError(Config(watchdogSeconds: 600, sleepSeconds: 1, rateLimitSleepSeconds: 60)) == ""

  test "rejects negative values and values not above the longest sleep":
    check watchdogConfigError(Config(watchdogSeconds: -1)).len > 0
    check watchdogConfigError(Config(watchdogSeconds: 60, rateLimitSleepSeconds: 60)).len > 0
    check watchdogConfigError(Config(watchdogSeconds: 30, sleepSeconds: 45, rateLimitSleepSeconds: 10)).len > 0
