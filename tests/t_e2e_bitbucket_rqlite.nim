import std/[json, os, strutils, unittest]

proc statementSql(stmt: JsonNode): string =
  if stmt.kind == JString:
    return stmt.getStr
  if stmt.kind == JArray and stmt.len > 0 and stmt[0].kind == JString:
    return stmt[0].getStr
  ""

proc loadStatements(path: string): seq[JsonNode] =
  for line in lines(path):
    if line.strip.len == 0:
      continue

    let batch = parseJson(line)
    check batch.kind == JArray
    for stmt in batch:
      result.add(stmt)

proc hasRepoInsert(statements: seq[JsonNode], repo: string): bool =
  for stmt in statements:
    if stmt.kind == JArray and
        statementSql(stmt).contains("INSERT INTO repos") and
        stmt.len >= 3 and
        stmt[1].getStr == "test" and
        stmt[2].getStr == repo:
      return true

proc hasBranchInsert(
  statements: seq[JsonNode],
  repo, branch, commitHash, commitHash7: string
): bool =
  for stmt in statements:
    if stmt.kind == JArray and
        statementSql(stmt).contains("INSERT INTO repo_branches") and
        stmt.len >= 6 and
        stmt[1].getStr == "test" and
        stmt[2].getStr == repo and
        stmt[3].getStr == branch and
        stmt[4].getStr == commitHash and
        stmt[5].getStr == commitHash7:
      return true

suite "e2e Bitbucket to rqlite":
  test "synchronizes repositories and branches into rqlite execute statements":
    let logPath = getEnv("E2E_RQLITE_LOG")
    check logPath.len > 0
    check fileExists(logPath)

    let statements = loadStatements(logPath)
    let allStatements = $statements

    check statements.len >= 6
    check allStatements.contains("CREATE TABLE IF NOT EXISTS repos")
    check allStatements.contains("CREATE TABLE IF NOT EXISTS repo_branches")
    check hasRepoInsert(statements, "dev-api")
    check not hasRepoInsert(statements, "ops-tool")
    check hasBranchInsert(
      statements,
      "dev-api",
      "main",
      "abcdef1234567890",
      "abcdef1"
    )
    check hasBranchInsert(
      statements,
      "dev-api",
      "release",
      "1234567890abcdef",
      "1234567"
    )
    check allStatements.contains("DELETE FROM repo_branches")
    check allStatements.contains("DELETE FROM repos")
