import std/[json, unittest]

import ../bitbucket_rqlite_cache

suite "configuration parsing helpers":
  test "parses integer values":
    check parseIntValue("SYNC_SLEEP_SECONDS", "", 3) == 3
    check parseIntValue("SYNC_SLEEP_SECONDS", "42", 3) == 42

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
