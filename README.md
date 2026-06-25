# Bitbucket rqlite Cache

A lightweight daemon that continuously synchronizes Bitbucket repository and branch metadata into rqlite.

The primary goal is to reduce Bitbucket API usage by providing a local SQL cache that can be queried by other automation tools.

## Features

- Single-threaded
- Continuous synchronization
- One Bitbucket request at a time
- Configurable delay between repositories
- Automatic retry after HTTP 429 (rate limiting)
- Batch updates to rqlite
- Automatic cleanup of deleted repositories
- Automatic cleanup of deleted branches
- HTTP Basic authentication support for Bitbucket
- HTTP Basic authentication support for rqlite
- No external Nim dependencies (stdlib only)

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

Compile:

```bash
nim c \
    -d:release \
    -d:ssl \
    --mm:orc \
    --threads:on \
    bitbucket_rqlite_cache.nim
```

## Docker

Build image:

```bash
docker build -t bitbucket-rqlite-cache .
```

Run:

```bash
docker run --rm \
  -e BITBUCKET_USER=user \
  -e BITBUCKET_TOKEN=app-password \
  -e RQLITE_USER=admin \
  -e RQLITE_PASSWORD=secret \
  bitbucket-rqlite-cache
```

## Environment variables

### Bitbucket

```bash
export BITBUCKET_USER='user@example.com'
export BITBUCKET_TOKEN='bitbucket-app-password'
```

### rqlite

```bash
export RQLITE_USER='admin'
export RQLITE_PASSWORD='secret'
```

## Command line options

| Option | Default | Description |
|--------|---------|-------------|
| `--workspace` | `test` | Bitbucket workspace |
| `--repo-prefix` | *(empty)* | Synchronize only repositories with the specified prefix |
| `--rqlite-url` | `http://127.0.0.1:4001` | rqlite HTTP endpoint |
| `--sleep` | `1` | Delay between repositories |
| `--rate-limit-sleep` | `60` | Delay after HTTP 429 |
| `--once` | | Run one synchronization cycle and exit |
| `--help` | | Show usage information |

## Examples

Synchronize all repositories:

```bash
./bitbucket_rqlite_cache \
    --workspace test \
    --rqlite-url http://rqlite:4001
```

Synchronize only repositories starting with `dev-`:

```bash
./bitbucket_rqlite_cache \
    --repo-prefix dev-
```

Run a single synchronization cycle:

```bash
./bitbucket_rqlite_cache --once
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

## License

MIT