#!/bin/sh
set -eu

nimble_dir="${NIMBLE_DIR:-build/nimble}"

mkdir -p "$nimble_dir"

if [ ! -f "$nimble_dir/packages_official.json" ]; then
  printf '[]\n' > "$nimble_dir/packages_official.json"
fi

if [ ! -f "$nimble_dir/packages_temp.json" ]; then
  printf '[]\n' > "$nimble_dir/packages_temp.json"
fi

if [ ! -f "$nimble_dir/official-nim-releases.json" ]; then
  printf '[]\n' > "$nimble_dir/official-nim-releases.json"
fi

if [ ! -f "$nimble_dir/nimbledata2.json" ]; then
  printf '{"version":1,"reverseDeps":{}}\n' > "$nimble_dir/nimbledata2.json"
fi

nimble --offline --nimbleDir:"$nimble_dir" buildRelease -y
