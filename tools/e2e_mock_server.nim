import std/[asynchttpserver, asyncdispatch, json, os, strformat, strutils]

proc jsonHeaders(): HttpHeaders =
  newHttpHeaders({"Content-Type": "application/json"})

proc rqliteResponse(body: string): string =
  var results = newJArray()

  try:
    let data = parseJson(body)
    if data.kind == JArray:
      for _ in data:
        results.add(newJObject())
    else:
      results.add(newJObject())
  except JsonParsingError:
    results.add(%*{"error": "invalid json"})

  $(%*{"results": results})

proc main() =
  if paramCount() != 3:
    quit("Usage: e2e_mock_server HOST PORT RQLITE_LOG")

  let host = paramStr(1)
  let port = Port(parseInt(paramStr(2)))
  let rqliteLog = paramStr(3)
  let logDir = parentDir(rqliteLog)
  if logDir.len > 0:
    createDir(logDir)

  var server = newAsyncHttpServer()

  proc callback(req: Request) {.async, gcsafe.} =
    let path = req.url.path

    if path == "/health":
      await req.respond(Http200, "ok")
      return

    if path == "/db/execute" and req.reqMethod == HttpPost:
      var log = open(rqliteLog, fmAppend)
      try:
        log.writeLine(req.body)
      finally:
        log.close()

      await req.respond(Http200, rqliteResponse(req.body), jsonHeaders())
      return

    if path == "/2.0/repositories/test/":
      await req.respond(Http200, $(%*{
        "values": [
          {"slug": "dev-api"},
          {"slug": "ops-tool"}
        ]
      }), jsonHeaders())
      return

    if path == "/2.0/repositories/test/dev-api/refs/branches":
      await req.respond(Http200, $(%*{
        "values": [
          {
            "name": "main",
            "target": {
              "hash": "abcdef1234567890",
              "date": "2026-07-01T10:00:00+00:00"
            }
          },
          {
            "name": "release",
            "target": {
              "hash": "1234567890abcdef",
              "date": "2026-07-01T11:00:00+00:00"
            }
          }
        ]
      }), jsonHeaders())
      return

    await req.respond(Http404, &"not found: {path}")

  waitFor server.serve(port, callback, address = host)

when isMainModule:
  main()
