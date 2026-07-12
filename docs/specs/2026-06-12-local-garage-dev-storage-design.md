# Local Garage Dev Storage — Design

**Date:** 2026-06-12
**Status:** Approved design, ready for implementation plan

## Goal

Make S3 storage actually work in local development. Today `Tore.Storage.S3` is
correct but dormant: no Garage server runs on `localhost:3900` and the
`GARAGE_*` env vars are unset, so the only real caller
(`Tore.Recipes.generate_image`) silently no-ops and boot logs a harmless
`Could not ensure S3 bucket … exists` warning. Stand up a local **Garage**
(self-hosted, S3-compatible) via Docker Compose so recipe images land in a real
bucket, with exact dev/prod software parity (prod already runs Garage).

This is **pure additive infrastructure** — no application code changes, no
existing test changes. The suite stays on `Tore.Storage.Mock` and remains
483/0.

## Background (verified during investigation)

- `config/config.exs:74-83` already points dev's `ex_aws`/`:s3` at
  `http://localhost:3900`, `path_style: true`, region `"garage"`, with creds
  read from `{:system, "GARAGE_ACCESS_KEY_ID"}` / `{:system, "GARAGE_SECRET_ACCESS_KEY"}`.
  ex_aws **2.6.1 does resolve `{:system, …}` tuples** via
  `ExAws.Config.retrieve_runtime_value/2` (`System.get_env`) — so once the env
  vars are set, dev picks up the creds with no config change. (An earlier memory
  note claiming "`{:system,…}` is dead in ex_aws 2.6" was wrong; corrected.)
- `lib/tore/storage/s3.ex:38-52` `ensure_buckets_exist/0` calls
  `ExAws.S3.put_bucket(bucket, "garage")` for each of
  `Tore.Storage.Buckets.all/0` = `["tore-recipes", "tore-receipts", "tore-uploads"]`,
  treating an HTTP 409 (already exists) as `:ok`. It runs **dev-only**, 500 ms
  after boot (`lib/tore/application.ex:31-36`).
- `region = "garage"` in config matches the `put_bucket(_, "garage")` call and the
  `garage.toml` `s3_region`.
- Prod (`config/runtime.exs:89-100`, inside `if config_env() == :prod`) uses
  `System.fetch_env!` for the same creds + `GARAGE_HOST`/`GARAGE_PORT` and sets
  `:storage_client` to `Tore.Storage.S3`. Dev sets `:storage_client` to
  `Tore.Storage.S3` in `config/dev.exs:85`. Test uses `Tore.Storage.Mock`.

## Image storage policy (derived from the SPEC's end-goal)

The SPEC's governing philosophy is *"keep the meaning, discard the pixels"*: a
photo is a **vision input** that the LLM parses into a structured belief; the
belief persists, the image does not. Tracing every image source against the SPEC:

| Source | SPEC intent | Store the image? |
|---|---|---|
| **Recipe images** (AI-gen + scraped) | "Garage (S3) for images" (line 46); recipes have a durable visual identity shown repeatedly | ✅ **Yes — `tore-recipes`** (the one durable visual artifact; already wired) |
| **Receipts** (`:receipt_ingestion_run`, §5) | Artifact is `CostEntry` + `PantryBeliefUpdate`; "optional photo path" | ❌ No — treat like any vision input: parse → `CostEntry`, discard |
| **Fridge photos** (`:fridge_rescue_run`) | "Photo → recipe suggestions"; nothing persists the photo | ❌ No — ephemeral |
| **Shelf/pantry photos** | `PantryBeliefUpdate` with `provenance: :shelf_photo`; the belief persists, not the photo | ❌ No |
| **Deal flyers** (`:deal_capture_run`) | `DealsUpdate`, provenance `:vision` | ❌ No |
| **Pantry thumbnails** | Not in the SPEC; contradicts the "approximate beliefs, not catalog" model | ❌ No |

**Decision: the only durably-stored image is the recipe image. The dev backend
provisions exactly one bucket, `tore-recipes`.** This is the single bucket with a
live writer (`Tore.Recipes.generate_image` → `put_object(Buckets.recipes(), …)`)
and the only one the end-goal justifies keeping. Future vision features
(`:receipt_ingestion_run` #5, `:fridge_rescue_run` #6) discard their input image
after extraction per this policy; they do not need a bucket.

### Pre-existing inconsistencies noted (NOT fixed by this task)

Recording these so they are not lost; both are out of scope for this infra task:

- `Tore.Storage.Buckets.all/0` still lists `tore-recipes`, `tore-receipts`,
  `tore-uploads`. The latter two are **dead** — no `put_object` targets them.
  Per the policy above they could be pruned to `[tore-recipes]` (a small code +
  `storage_mock_test.exs` change), but that is a separate cleanup, not this
  storage-provisioning task.
- `Tore.Costs.confirm_receipt` writes the receipt photo to **local disk**
  (`store_receipt_image` → `priv/static/uploads/receipts/…`), which already
  violates the "discard the pixels" policy. Whether to stop storing it (drop the
  disk write) or keep it is a decision for when `:receipt_ingestion_run` (#5) is
  built. Left untouched here.

## Decisions (resolved during brainstorming)

1. **Garage, not MinIO**, for dev — exact prod parity (same software), accepting
   a one-time bootstrap cost over MinIO's zero-bootstrap convenience.
2. **Docker Compose**, not a native install — keeps the zero-server philosophy
   (the app's only datastore is SQLite); Garage becomes a declared, disposable
   dependency. `docker` is already on PATH.
3. **Readiness is declarative** — a Compose healthcheck (`garage status`) plus
   `docker compose up -d --wait`; no `sleep`, no app-side polling loop.
4. **Keys persist in the named volume** — bootstrap (layout + key + buckets) is a
   **once-ever** cold-start event, not per-startup. `compose stop/start/restart`,
   reboot, and `compose down` (without `-v`) all reuse the existing metadata.
   Only `compose down -v` forces a re-bootstrap.
5. **`.env`-authoritative creds via `garage key import`** — `garage key import
   <key-id> <secret-key> --yes` exists in v2.3 (verified against the
   `dxflrs/garage:v2.3.0` binary; the published docs omit it). You set chosen
   `GARAGE_ACCESS_KEY_ID` (a `GK`-prefixed id) and `GARAGE_SECRET_ACCESS_KEY` (hex)
   in `.env` once; the bootstrap imports them. No output parsing, no script
   mutating `.env` — `.env` is the single source of truth. Idempotent: skip the
   import if the key already exists.

## Components (new files)

### 1. `compose.yml` — the Garage service

```yaml
services:
  garage:
    image: dxflrs/garage:v2.3.0
    container_name: tore-garage
    network_mode: host          # simplest path-style S3 on localhost:3900
    volumes:
      - ./garage.toml:/etc/garage.toml:ro
      - garage-meta:/var/lib/garage/meta
      - garage-data:/var/lib/garage/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/garage", "status"]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 3s

volumes:
  garage-meta:
  garage-data:
```

Notes for the implementer:
- `network_mode: host` avoids Docker NAT quirks with S3 path-style addressing and
  keeps `localhost:3900` working for both the BEAM and the healthcheck. If host
  networking is undesirable, the fallback is explicit `ports: ["3900:3900",
  "3901:3901", "3903:3903"]` and binding the API to `[::]` in `garage.toml`
  (already the case below). **Default to host networking;** note the port-mapping
  fallback in a comment.
- The healthcheck uses Garage's own `garage status` (verified as the readiness
  command). The binary path inside the `dxflrs/garage` image is `/garage` — the
  plan's first task must confirm this with `docker compose exec garage /garage
  status` and adjust if the path differs.

### 2. `garage.toml` — single-node dev config

```toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"

replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "REPLACE_WITH_openssl_rand_hex_32"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "[::]:3903"
admin_token = "REPLACE_WITH_openssl_rand_base64_32"
```

Notes:
- `s3_region = "garage"` MUST stay — it matches `config/config.exs` and the
  `put_bucket(_, "garage")` call.
- `rpc_secret` and `admin_token` are placeholders. This file IS committed (it is
  dev-local config, not a secret store), but the `rpc_secret`/`admin_token` are
  local-only dev values. Generate them once with `openssl rand -hex 32` /
  `openssl rand -base64 32` and commit the concrete dev values (a local Garage
  RPC secret is not a production secret). The plan generates and inlines real
  values rather than leaving the `REPLACE_…` placeholders.

### 3. `bin/garage-bootstrap.sh` — once-ever, idempotent provisioning

Run after Garage is healthy. Provisions the single node, imports the access key
from `.env`, and creates+grants the `tore-recipes` bucket (the only one with a
live writer — see Image storage policy). Reads creds from `.env`; every step
guarded so re-runs are safe no-ops.

```sh
#!/usr/bin/env sh
set -eu

GARAGE="docker compose exec -T garage /garage"
KEY_NAME="tore-dev"
BUCKET="tore-recipes"   # only bucket with a live writer (see Image storage policy)

# Creds come from .env (the source of truth). Must be set before running.
: "${GARAGE_ACCESS_KEY_ID:?set GARAGE_ACCESS_KEY_ID in .env}"
: "${GARAGE_SECRET_ACCESS_KEY:?set GARAGE_SECRET_ACCESS_KEY in .env}"

# 1. Cluster layout — assign this single node if no layout version is applied yet.
if ! $GARAGE layout show 2>/dev/null | grep -qE "version[[:space:]]+[1-9]"; then
  NODE_ID=$($GARAGE node id -q 2>/dev/null | cut -d@ -f1)
  $GARAGE layout assign -z dc1 -c 1G "$NODE_ID"
  $GARAGE layout apply --version 1
fi

# 2. Access key — import the chosen creds only if our named key does not exist.
if ! $GARAGE key list 2>/dev/null | grep -q "$KEY_NAME"; then
  $GARAGE key import --yes -n "$KEY_NAME" "$GARAGE_ACCESS_KEY_ID" "$GARAGE_SECRET_ACCESS_KEY"
fi

# 3. Bucket — create + grant the key (each guarded; create is a no-op if present).
$GARAGE bucket create "$BUCKET" 2>/dev/null || true
$GARAGE bucket allow --read --write "$BUCKET" --key "$KEY_NAME" 2>/dev/null || true

echo "Garage bootstrap complete."
```

Verified CLI facts (against the `dxflrs/garage:v2.3.0` binary, `--help`):
- `garage key import [--yes] [-n <name>] <key-id> <secret-key>` — exists (docs omit
  it). `--yes` confirms; `-n` names the key.
- `garage bucket allow [--read] [--write] [--owner] <bucket> --key <key-pattern>` —
  use `--read --write` only; the app only puts/gets/deletes objects, never owns.
- `garage layout assign [-z <zone>] [-c <capacity>] <node-ids>...` and
  `garage layout apply --version <n>`.
- `garage key list` / `garage layout show` for the idempotency guards.

Implementer notes:
- The node-id retrieval (`garage node id -q`) and the exact `layout show` version
  string MUST be confirmed live in Task 1 against a running node and the guards
  adjusted to the real output (the image pulls and runs locally — the implementer
  can probe it). The shape above is correct per `--help`; only the runtime output
  formats of `node id` / `layout show` need a live confirm.
- The script must be run with `.env` already sourced (so `GARAGE_ACCESS_KEY_ID` /
  `GARAGE_SECRET_ACCESS_KEY` are in the environment) — `bin/dev` sources `.env`
  before calling it. Run standalone as `set -a; . ./.env; set +a; ./bin/garage-bootstrap.sh`.

### 4. `bin/dev` — one-command dev startup

```sh
#!/usr/bin/env sh
set -eu

# First run: seed .env from example and stop so the user fills in their creds
# (chosen GARAGE_* values + OPENROUTER_API_KEY) before anything uses them.
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example. Fill in GARAGE_* creds + API keys, then re-run bin/dev."
  exit 1
fi

# Load env FIRST — the bootstrap imports GARAGE_ACCESS_KEY_ID/SECRET into Garage.
set -a
. ./.env
set +a

# Bring up Garage and BLOCK until its healthcheck passes (no sleep, no poll loop).
docker compose up -d --wait

# Provision once / no-op on subsequent runs (imports the .env creds, makes bucket).
./bin/garage-bootstrap.sh

exec mix phx.server
```

Notes:
- `docker compose up -d --wait` returns only when the `garage` service is
  `healthy` (or errors out) — this is the entire readiness mechanism.
- `exec mix phx.server` hands the terminal to Phoenix as the foreground process
  (Ctrl-C behaves normally); Garage stays detached in the background.
- Both `bin/` scripts are `chmod +x`.
- Ordering: `.env` is sourced **before** the bootstrap, because the bootstrap
  imports `GARAGE_ACCESS_KEY_ID`/`SECRET` into Garage. First run seeds `.env` and
  exits so the user fills in chosen creds; every run after sources `.env`, brings
  up Garage, imports the key (no-op if already imported), and starts Phoenix with
  the same creds the app reads. `.env` is the single source of truth — no script
  ever mutates it.

### 5. `.env.example` — committed template

```
# OpenRouter (you provide)
OPENROUTER_API_KEY=

# Local Garage S3 — you CHOOSE these once; bin/garage-bootstrap.sh imports them.
# Key id must be a GK-prefixed 28-char string; secret a 64-char hex string.
# Generate e.g.: GARAGE_ACCESS_KEY_ID="GK$(openssl rand -hex 13)"
#                GARAGE_SECRET_ACCESS_KEY="$(openssl rand -hex 32)"
GARAGE_ACCESS_KEY_ID=
GARAGE_SECRET_ACCESS_KEY=
GARAGE_HOST=localhost
GARAGE_PORT=3900
```

Implementer note: include whatever other env vars the dev runtime already expects
(scan `config/runtime.exs` + `config/dev.exs` for `System.get_env` keys used in
dev) so `.env.example` is a complete template. Do NOT invent new ones.

### 6. `.gitignore` — protect the real `.env`

Ensure `.env` is ignored (add if absent). `.env.example`, `compose.yml`,
`garage.toml`, and `bin/*` ARE committed. The Garage data lives in **named
volumes** (`garage-meta`, `garage-data`), so no local data directory needs
ignoring — confirm no bind-mount path leaks into the repo.

### 7. README — a short "Local development" section

Document the flow: `cp .env.example .env` (or just run `bin/dev` which seeds it),
fill in `OPENROUTER_API_KEY`, run `bin/dev`. Explain that Garage state persists in
Docker volumes (restarts reuse it; `docker compose down -v` wipes it and forces a
re-bootstrap on next `bin/dev`). Keep the existing `mix setup` / `mix phx.server`
instructions — `bin/dev` is the convenience front door, not a replacement.

## Verification (manual, user-run — no secrets read by the implementer)

The implementer CANNOT fully verify this without Docker + a running Garage, and
MUST NOT read or generate the user's real OpenRouter key. The plan's final task is
a documented smoke check for the **user** to run:

1. `bin/dev` (first run seeds `.env`; user reviews; re-runs).
2. Confirm `docker compose ps` shows `garage` healthy.
3. Confirm `docker compose exec garage /garage key list` shows the `tore-dev`
   key (proving the import succeeded with the `.env` creds).
4. Confirm `docker compose exec garage /garage bucket list` shows
   `tore-recipes`.
5. With the app running, generate a recipe image; confirm the object lands
   (`docker compose exec garage /garage bucket info tore-recipes` shows >0
   objects) and the stored `image_path` URL resolves.

The implementer-runnable gate is narrower but real:
- `mix test` stays **483/0** (no test touches Garage; Mock unchanged).
- `mix compile --warnings-as-errors` clean (no code changed, so trivially).
- `docker compose config` parses `compose.yml` without error.
- `sh -n bin/dev bin/garage-bootstrap.sh` (syntax check) passes.

## Out of scope

- No application code changes; no change to `Tore.Storage.*`, `application.ex`,
  or any config file (the existing `{:system,…}` + `localhost:3900` dev config
  already works once creds are present).
- No prod deployment changes (`runtime.exs` prod block already correct).
- No auto-loading of `.env` into `mix` via a `dotenvy` dep — `bin/dev` sources it
  explicitly; standalone `mix phx.server` users source `.env` themselves.
- Not provisioning `tore-receipts`/`tore-uploads` — they have no live writer and
  the end-goal does not store those images (see Image storage policy). Future
  vision features (#5/#6) discard their input image after extraction.
- Not pruning the dead `tore-receipts`/`tore-uploads` from `Buckets.all/0`, and
  not changing the receipt disk-write in `Tore.Costs.confirm_receipt` — both noted
  as pre-existing inconsistencies above, both separate from this infra task.
