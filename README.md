# Bitbucket rqlite Cache

A lightweight daemon that continuously synchronizes Bitbucket repository and branch metadata into rqlite.

The primary goal is to reduce Bitbucket API usage by providing a local SQL cache that can be queried by other automation tools.

## Features

- Single-threaded
- Continuous synchronization
- One Bitbucket request at a time
- Configurable delay between repositories
- Automatic retry after HTTP 429 (rate limiting)
- A new connection for every rqlite request, so a proxy that closes idle
  connections (an ingress) does not break the next write
- A watchdog that exits with code 3 when nothing progresses for
  `WATCHDOG_SECONDS`, so that Kubernetes restarts a stuck daemon
- Batch updates to rqlite
- Automatic cleanup of deleted repositories
- Automatic cleanup of deleted branches
- HTTP Basic authentication support for Bitbucket
- HTTP Basic authentication support for rqlite
- Uses `posixglob` for repository pattern matching

## Database schema

### repos

| Column | Description |
|---------|-------------|
| workspace | Bitbucket workspace |
| repo | Repository name |
| updated_at | Last successful synchronization |
| last_error | Last synchronization error |

### repo_branches

| Column | Description |
|---------|-------------|
| workspace | Bitbucket workspace |
| repo | Repository name |
| branch | Branch name |
| commit_hash | Full commit SHA |
| commit_hash7 | First seven characters of commit SHA |
| commit_date | Commit timestamp |
| updated_at | Last successful synchronization |

## Synchronization flow

```text
loop forever

    fetch repository list

    update repos table

    for each repository

        fetch all branches

        batch upsert all branches

        delete removed branches

        sleep

    delete removed repositories
```

Only one Bitbucket request is executed at a time, making the application suitable for environments with strict API rate limits.

## Build

Requirements:

- Nim 2.2+
- OpenSSL development package

Run tests:

```bash
nimble test -y
```

Build release binary:

```bash
nimble buildRelease -y
```

The release binary is written to `build/bitbucket-rqlite-cache`.

Full local release checks:

```bash
nimble test -y
nimble buildRelease -y
helm lint helm/bitbucket-rqlite-cache
helm template bitbucket-rqlite-cache helm/bitbucket-rqlite-cache
docker build -t bitbucket-rqlite-cache:test .
```

## CI

GitHub Actions, in `.github/workflows/`:

| Workflow | Runs on | What it does |
|----------|---------|--------------|
| `ci.yaml` | push to `main`, pull request, tag `v*`, manual | `nimble test`, release binary, `helm lint` and `helm template`, amd64 image build. Publishes nothing. |
| `ci.yaml` | tag `v*` only, in addition | Checks that the tag equals the nimble `version` and the chart `version` and `appVersion`; pushes the image for amd64 and arm64, pushes the chart, creates the GitHub release. |

Tests and the binary are built in the `nimlang/nim` builder image named in
the `Dockerfile`; the chart is checked in the `alpine/helm` image named in
`tools/helm/Dockerfile` (that file is never built). `ci.yaml` reads both
`FROM` lines, so each image is pinned in one place.

Publishing uses the workflow's own `GITHUB_TOKEN`; no secret is needed. The
first release creates the GHCR packages `bitbucket-rqlite-cache` and
`charts/bitbucket-rqlite-cache`, linked to this repository.

## Dependency updates

Dependabot (`.github/dependabot.yml`) opens pull requests once a week for:

- the actions in `.github/workflows/`, pinned by commit SHA;
- the images in `Dockerfile` and `tools/helm/Dockerfile`, pinned by tag and
  digest.

The Nim package `posixglob` is installed from its repository at build time
and is not pinned; Dependabot does not watch it.

## Docker

Build image:

```bash
docker build -t bitbucket-rqlite-cache .
```

## Helm

Install from the local chart:

```bash
helm install bitbucket-rqlite-cache ./helm/bitbucket-rqlite-cache \
  --set env.BITBUCKET_WORKSPACE=test \
  --set env.BITBUCKET_USER=user \
  --set env.BITBUCKET_TOKEN=app-password \
  --set env.RQLITE_URL=http://rqlite:4001
```

The chart can also read all environment variables from an existing Secret:

```bash
helm install bitbucket-rqlite-cache ./helm/bitbucket-rqlite-cache \
  --set existingSecret.name=bitbucket-rqlite-cache
```

Run:

```bash
docker run --rm \
  -e BITBUCKET_WORKSPACE=test \
  -e BITBUCKET_USER=user \
  -e BITBUCKET_TOKEN=app-password \
  -e RQLITE_URL=http://rqlite:4001 \
  -e RQLITE_USER=admin \
  -e RQLITE_PASSWORD=secret \
  bitbucket-rqlite-cache
```

## Environment variables

### Required

```bash
export BITBUCKET_WORKSPACE='test'
export BITBUCKET_USER='user@example.com'
export BITBUCKET_TOKEN='bitbucket-app-password'
export RQLITE_URL='http://rqlite:4001'
```

### Optional

```bash
export BITBUCKET_REPO_PATTERNS=''
export BITBUCKET_API_URL='https://api.bitbucket.org/2.0/repositories'
export SYNC_SLEEP_SECONDS='1'
export BITBUCKET_RATE_LIMIT_SLEEP_SECONDS='60'
export WATCHDOG_SECONDS='600'
export RQLITE_USER='admin'
export RQLITE_PASSWORD='secret'
```

## Configuration

| Environment variable | Default | Description |
|----------------------|---------|-------------|
| `BITBUCKET_WORKSPACE` | required | Bitbucket workspace |
| `BITBUCKET_REPO_PATTERNS` | *(empty)* | Comma-separated repository glob patterns to synchronize |
| `BITBUCKET_API_URL` | `https://api.bitbucket.org/2.0/repositories` | Bitbucket repositories API base URL; useful for e2e tests and mocks |
| `RQLITE_URL` | required | rqlite HTTP endpoint |
| `SYNC_SLEEP_SECONDS` | `1` | Delay between repositories |
| `BITBUCKET_RATE_LIMIT_SLEEP_SECONDS` | `60` | Delay after HTTP 429 |
| `WATCHDOG_SECONDS` | `600` | Exit with code 3 when no Bitbucket or rqlite request has finished and no sleep has ended for this many seconds. `0` turns the watchdog off. Must be greater than `SYNC_SLEEP_SECONDS` and `BITBUCKET_RATE_LIMIT_SLEEP_SECONDS`; the program refuses to start otherwise. Read at start; a change needs a restart. |
| `BITBUCKET_USER` | required | Bitbucket username or email |
| `BITBUCKET_TOKEN` | required | Bitbucket app password |
| `RQLITE_USER` | *(empty)* | rqlite username |
| `RQLITE_PASSWORD` | *(empty)* | rqlite password |

## Command line flags

| Flag | Description |
|------|-------------|
| `--once` | Run one synchronization cycle and exit |
| `--help` | Show usage information |

## Examples

Synchronize all repositories:

```bash
BITBUCKET_WORKSPACE=test \
RQLITE_URL=http://rqlite:4001 \
./build/bitbucket-rqlite-cache
```

Synchronize only repositories matching one of the configured patterns:

```bash
BITBUCKET_REPO_PATTERNS='dev-*,ops-*' ./build/bitbucket-rqlite-cache
```

Pattern lists are parsed with `posixglob.parseGlobPatterns()` and each item uses
POSIX glob syntax. The comma is not part of the glob syntax; it separates list
items before matching.

Run a single synchronization cycle:

```bash
./build/bitbucket-rqlite-cache --once
```

## Example SQL queries

Get the current commit for the `prod` branch:

```sql
SELECT commit_hash7
FROM repo_branches
WHERE repo = 'dev-payments'
  AND branch = 'dev';
```

List all repositories and their current `prod` commit:

```sql
SELECT
    repo,
    commit_hash7,
    commit_date
FROM repo_branches
WHERE branch = 'prod'
ORDER BY repo;
```

Find branches that have not changed recently:

```sql
SELECT
    repo,
    branch,
    commit_date
FROM repo_branches
ORDER BY commit_date;
```

## Release process

1. Update `version` in `bitbucket_rqlite_cache.nimble`.
2. Update `version` and `appVersion` in `helm/bitbucket-rqlite-cache/Chart.yaml`.
3. Run the full local release checks from the Build section.
4. Commit the release changes.
5. Create and push a matching tag, for example:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The tag pipeline fails at once if the tag does not match the versions from
steps 1 and 2. The arm64 image is built under emulation and takes several
minutes; do not cancel it. Tagged releases publish:

- Linux amd64 binary, its SHA256 checksum and the license to GitHub Releases
- Docker image (amd64, arm64) to `ghcr.io/<owner>/<repo>`, tagged `X.Y.Z`, `vX.Y.Z` and `latest`
- Helm chart to `oci://ghcr.io/<owner>/charts`

## License

MIT
