# Package
version       = "0.1.0"
author        = "zystem"
description   = "Synchronize Bitbucket repository and branch metadata into rqlite"
license       = "MIT"

srcDir        = "src"
bin           = @["bitbucket_rqlite_cache"]

# Dependencies
requires "nim >= 2.2.0"
requires "posixglob >= 0.1.6"

# Tasks
task test, "Run the test suite":
  mkDir "build"
  mkDir "build/nimcache"
  exec "nimble c -r -d:ssl --threads:on --mm:orc --nimcache:build/nimcache/test-core --out:build/t_core tests/t_core.nim"
  exec "nimble c --threads:on --mm:orc --nimcache:build/nimcache/e2e-mock-server --out:build/e2e-mock-server tools/e2e_mock_server.nim"
  exec "nimble c -d:ssl --threads:on --mm:orc --nimcache:build/nimcache/e2e-app --out:build/bitbucket-rqlite-cache-e2e src/bitbucket_rqlite_cache.nim"
  exec "nimble c -r --threads:on --mm:orc --nimcache:build/nimcache/tester --out:build/tester tests/tester.nim"

task buildRelease, "Build the release binary":
  mkDir "build"
  exec "nimble c -d:release -d:ssl --threads:on --mm:orc --nimcache:build/nimcache/release --out:build/bitbucket-rqlite-cache src/bitbucket_rqlite_cache.nim"
