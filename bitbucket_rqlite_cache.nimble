version       = "0.1.0"
author        = "zystem"
description   = "Synchronize Bitbucket repository and branch metadata into rqlite"
license       = "MIT"
srcDir        = "."
bin           = @["bitbucket_rqlite_cache"]

requires "nim >= 2.2.0"

task test, "Run the test suite":
  exec "sh tests/run.sh"

task buildRelease, "Build the release binary":
  exec "mkdir -p build"
  exec "nim c -d:release -d:ssl --threads:on --mm:orc --nimcache:build/nimcache --out:build/bitbucket-rqlite-cache bitbucket_rqlite_cache.nim"
