import std/[httpclient, os, osproc, strtabs, strutils, times]

const
  MockUrl = "http://127.0.0.1:18081"
  RqliteLog = "build/e2e-rqlite.jsonl"

proc inheritedEnvironment(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value

proc waitUntilReady(process: Process) =
  let client = newHttpClient(timeout = 200)
  defer: client.close()

  for attempt in 0 ..< 10:
    if process.peekExitCode() != -1:
      quit("e2e mock server exited before becoming ready")

    try:
      if client.get(MockUrl & "/health").code == Http200:
        return
    except CatchableError:
      discard

    sleep(200)

  quit("e2e mock server did not become ready")

proc main() =
  writeFile(RqliteLog, "")

  let mock = startProcess(
    "build/e2e-mock-server",
    args = @["127.0.0.1", "18081", RqliteLog]
  )

  defer:
    if mock.peekExitCode() == -1:
      mock.terminate()
      discard mock.waitForExit()
    mock.close()

  waitUntilReady(mock)

  var appEnvironment = inheritedEnvironment()
  appEnvironment["BITBUCKET_API_URL"] = MockUrl & "/2.0/repositories"
  appEnvironment["BITBUCKET_WORKSPACE"] = "test"
  appEnvironment["BITBUCKET_REPO_PATTERNS"] = "dev-*"
  appEnvironment["BITBUCKET_USER"] = "user@example.com"
  appEnvironment["BITBUCKET_TOKEN"] = "app-password"
  appEnvironment["RQLITE_URL"] = MockUrl
  appEnvironment["SYNC_SLEEP_SECONDS"] = "0"

  appEnvironment["BITBUCKET_RATE_LIMIT_SLEEP_SECONDS"] = "0"

  let app = startProcess(
    "build/bitbucket-rqlite-cache-e2e",
    args = @["--once"],
    env = appEnvironment,
    options = {poParentStreams}
  )
  let appExitCode = app.waitForExit()
  app.close()
  if appExitCode != 0:
    quit("application e2e process failed with exit code " & $appExitCode)

  # A request that never ends must not stop the daemon for ever: the watchdog
  # exits with code 3 well before the client's 30 second timeout.
  var hangEnvironment = appEnvironment
  hangEnvironment["BITBUCKET_WORKSPACE"] = "hang"
  hangEnvironment["WATCHDOG_SECONDS"] = "2"
  let started = epochTime()
  let hanging = startProcess(
    "build/bitbucket-rqlite-cache-e2e",
    env = hangEnvironment,
    options = {poParentStreams}
  )
  let hangExitCode = hanging.waitForExit(timeout = 20_000)
  let hangSeconds = epochTime() - started
  if hanging.peekExitCode() == -1:
    hanging.terminate()
    discard hanging.waitForExit()
    hanging.close()
    quit("watchdog did not stop a hanging request within 20 seconds")
  hanging.close()
  if hangExitCode != 3:
    quit("watchdog e2e: expected exit code 3, got " & $hangExitCode)
  if hangSeconds > 10:
    quit("watchdog e2e: took " & $hangSeconds & " seconds, expected about 2")
  echo "watchdog e2e: exit code 3 after ", hangSeconds.formatFloat(ffDecimal, 1), " seconds"

  putEnv("E2E_RQLITE_LOG", RqliteLog)
  let testExitCode = execCmd(
    "nim c -r --threads:on --mm:orc " &
    "--nimcache:build/nimcache/test-e2e " &
    "--out:build/t_e2e_bitbucket_rqlite tests/t_e2e_bitbucket_rqlite.nim"
  )
  if testExitCode != 0:
    quit("e2e assertions failed with exit code " & $testExitCode)

when isMainModule:
  main()
