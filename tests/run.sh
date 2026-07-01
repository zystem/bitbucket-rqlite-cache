#!/bin/sh
set -eu

nim c -r -d:ssl --threads:on --mm:orc \
  --nimcache:build/nimcache \
  --out:build/t_core \
  tests/t_core.nim

nim c --threads:on --mm:orc \
  --nimcache:build/nimcache \
  --out:build/e2e-mock-server \
  tools/e2e_mock_server.nim

nim c -d:ssl --threads:on --mm:orc \
  --nimcache:build/nimcache \
  --out:build/bitbucket-rqlite-cache-e2e \
  bitbucket_rqlite_cache.nim

e2e_log=build/e2e-rqlite.jsonl
: > "$e2e_log"

./build/e2e-mock-server 127.0.0.1 18081 "$e2e_log" \
  > build/e2e-mock-server.log 2>&1 &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true' EXIT

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1:18081/health >/dev/null; then
    break
  fi
  sleep 0.2
done

BITBUCKET_API_URL=http://127.0.0.1:18081/2.0/repositories \
BITBUCKET_WORKSPACE=test \
BITBUCKET_REPO_PREFIX=dev- \
BITBUCKET_USER=user@example.com \
BITBUCKET_TOKEN=app-password \
RQLITE_URL=http://127.0.0.1:18081 \
SYNC_SLEEP_SECONDS=0 \
./build/bitbucket-rqlite-cache-e2e \
  --once \
  > build/e2e-app.log 2>&1

E2E_RQLITE_LOG="$e2e_log" \
nim c -r --threads:on --mm:orc \
  --nimcache:build/nimcache \
  --out:build/t_e2e_bitbucket_rqlite \
  tests/t_e2e_bitbucket_rqlite.nim
