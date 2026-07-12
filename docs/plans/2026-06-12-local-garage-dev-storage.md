# Local Garage Dev Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a local Garage (S3-compatible) via Docker Compose so `Tore.Storage.S3` actually stores recipe images in dev, with one-command startup (`bin/dev`).

**Architecture:** Pure additive infrastructure — a `compose.yml` (Garage v2.3.0, healthcheck, named volumes), a `garage.toml` (single node), `bin/garage-bootstrap.sh` (idempotent: layout + `key import` from `.env` + bucket), and `bin/dev` (source `.env` → `compose up --wait` → bootstrap → `mix phx.server`). No application code or test changes; the suite stays 483/0. Only the `tore-recipes` bucket is provisioned (the sole bucket with a live writer).

**Tech Stack:** Docker Compose, Garage v2.3.0 (`dxflrs/garage:v2.3.0`), POSIX sh, Elixir/Phoenix (unchanged), jj (Jujutsu) for VCS — **never git**.

**Spec:** `docs/specs/2026-06-12-local-garage-dev-storage-design.md`

---

## Critical conventions (read before starting)

- **VCS is jj, NOT git.** Commit with `jj commit -m "<msg>"`. Never run any `git`
  command. End commit messages with:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **No application code or test changes.** This is infra only. `mix test` must
  stay **483 tests, 0 failures**; `mix compile --warnings-as-errors` clean. Run
  `mix test` once now to confirm the 483/0 baseline.
- **Never read or generate the user's real secrets.** `.env` is gitignored and
  user-owned. The implementer writes `.env.example` (blank cred fields) only.
- **This plan's artifacts can't be fully end-to-end verified by the implementer**
  without the user's OpenRouter key (image generation needs the LLM/image-gen
  client). The implementer-runnable gates are: syntax checks, `docker compose
  config`, a live Garage bootstrap probe (Task 1 + Task 4), and the suite staying
  483/0. The final image-upload smoke check is documented for the **user** to run.
- **Verified CLI facts** (already confirmed against the `dxflrs/garage:v2.3.0`
  binary via `--help`; do not re-litigate, but Task 1 confirms two *runtime output*
  formats):
  - `garage key import [--yes] [-n <name>] <key-id> <secret-key>` — exists.
  - `garage bucket allow [--read] [--write] [--owner] <bucket> --key <pat>`.
  - `garage layout assign [-z <zone>] [-c <cap>] <node-ids>...`;
    `garage layout apply --version <n>`.
  - `garage key list`, `garage layout show`, `garage status`, `garage bucket list`.

---

## File structure (all new, except .gitignore + README)

| File | Responsibility |
|---|---|
| `compose.yml` | Garage service: image, host networking, volumes, healthcheck |
| `garage.toml` | Single-node Garage config (region `garage`, ports, secrets) |
| `bin/garage-bootstrap.sh` | Idempotent: layout apply → key import (from `.env`) → bucket create+allow |
| `bin/dev` | One-command dev: seed/source `.env` → `compose up --wait` → bootstrap → `phx.server` |
| `.env.example` | Committed template; blank cred fields the user fills |
| `.gitignore` | Add `.env` (if absent) |
| `README.md` | A "Local development" subsection |

---

## Task 1: Compose + config + a live bootstrap probe

Create the Garage service and config, and **probe the running node** to confirm
the two runtime-output formats the bootstrap's idempotency guards depend on
(`garage node id` and `garage layout show`).

**Files:**
- Create: `compose.yml`, `garage.toml`

- [ ] **Step 1: Write `garage.toml`**

Generate two real local secrets first (these are dev-local, not production
secrets — they get committed):
```bash
echo "rpc_secret = \"$(openssl rand -hex 32)\""
echo "admin_token = \"$(openssl rand -base64 32)\""
```
Write `garage.toml` with the generated values inlined (replace the two
`GENERATED_*` below with the command output):
```toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"

replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "GENERATED_HEX_32"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "[::]:3903"
admin_token = "GENERATED_BASE64_32"
```

- [ ] **Step 2: Write `compose.yml`**

```yaml
services:
  garage:
    image: dxflrs/garage:v2.3.0
    container_name: tore-garage
    network_mode: host
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

- [ ] **Step 3: Validate the compose file parses**

Run: `docker compose config`
Expected: prints the resolved config, exit 0, no error.

- [ ] **Step 4: Bring Garage up and wait for healthy**

Run: `docker compose up -d --wait`
Expected: returns 0 once the `garage` service is healthy (the `garage status`
healthcheck passes). If it errors, inspect `docker compose logs garage` — a common
cause is a malformed `garage.toml` (Garage refuses to start) or the host already
using port 3900.

- [ ] **Step 5: PROBE the two runtime output formats (the only unverified bits)**

Run and record the exact output shape:
```bash
docker compose exec -T garage /garage node id -q
docker compose exec -T garage /garage status
docker compose exec -T garage /garage layout show
```
Note:
- How `node id -q` prints the node id (expected: `<hex-id>@<addr>`; the bootstrap
  takes the part before `@`). Confirm `-q` (quiet) exists; if not, parse `status`.
- What `layout show` prints when **no** layout is applied yet vs. after apply —
  specifically the string that indicates an applied version (the guard greps for
  `version[[:space:]]+[1-9]`). Adjust the guard in Task 2 to match the real text.

Write the observed formats into a comment at the top of `bin/garage-bootstrap.sh`
in Task 2 so the guards are provably correct, not guessed.

- [ ] **Step 6: Leave Garage running (Task 4 needs it). Commit the two files.**

```bash
jj commit -m "infra(garage): compose.yml + garage.toml for local dev S3

Garage v2.3.0 single-node on localhost:3900 (host networking), named volumes,
garage status healthcheck. Probed node-id/layout-show output for the bootstrap
guards. No app code touched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: The bootstrap script

Idempotent provisioning: layout (once) → import the `.env` key (once) → create +
grant the `tore-recipes` bucket. Uses the runtime formats confirmed in Task 1.

**Files:**
- Create: `bin/garage-bootstrap.sh`

- [ ] **Step 1: Write `bin/garage-bootstrap.sh`**

```sh
#!/usr/bin/env sh
set -eu

# Runtime output formats confirmed against dxflrs/garage:v2.3.0 in Task 1:
#   node id -q -> "<hex>@<addr>"  (take field before '@')
#   layout show (applied) -> contains "version <N>"   [ADJUST if Task 1 differs]

GARAGE="docker compose exec -T garage /garage"
KEY_NAME="tore-dev"
BUCKET="tore-recipes"   # only bucket with a live writer (see spec Image storage policy)

: "${GARAGE_ACCESS_KEY_ID:?set GARAGE_ACCESS_KEY_ID in .env}"
: "${GARAGE_SECRET_ACCESS_KEY:?set GARAGE_SECRET_ACCESS_KEY in .env}"

# 1. Cluster layout — assign this single node if no layout version applied yet.
if ! $GARAGE layout show 2>/dev/null | grep -qE "version[[:space:]]+[1-9]"; then
  NODE_ID=$($GARAGE node id -q 2>/dev/null | cut -d@ -f1)
  $GARAGE layout assign -z dc1 -c 1G "$NODE_ID"
  $GARAGE layout apply --version 1
fi

# 2. Access key — import the chosen .env creds only if our named key is absent.
if ! $GARAGE key list 2>/dev/null | grep -q "$KEY_NAME"; then
  $GARAGE key import --yes -n "$KEY_NAME" "$GARAGE_ACCESS_KEY_ID" "$GARAGE_SECRET_ACCESS_KEY"
fi

# 3. Bucket — create + grant (guarded; create is a no-op if it already exists).
$GARAGE bucket create "$BUCKET" 2>/dev/null || true
$GARAGE bucket allow --read --write "$BUCKET" --key "$KEY_NAME" 2>/dev/null || true

echo "Garage bootstrap complete."
```
Replace the `version[[:space:]]+[1-9]` guard and `node id -q` parsing with the
exact forms confirmed in Task 1 if they differ.

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/garage-bootstrap.sh`

- [ ] **Step 3: Syntax-check**

Run: `sh -n bin/garage-bootstrap.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Dry guard-check (creds-missing path)**

Run (with the vars unset): `env -u GARAGE_ACCESS_KEY_ID -u GARAGE_SECRET_ACCESS_KEY sh bin/garage-bootstrap.sh`
Expected: fails fast with `set GARAGE_ACCESS_KEY_ID in .env` (proves the `:?`
guards fire before any Garage call). Exit non-zero.

- [ ] **Step 5: Commit**

```bash
jj commit -m "infra(garage): bin/garage-bootstrap.sh (idempotent provisioning)

Layout apply (once) -> garage key import from .env (once) -> tore-recipes bucket
create + allow. Guards make re-runs no-ops; fails fast if .env creds are unset.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `bin/dev`, `.env.example`, `.gitignore`

The one-command front door plus the committed env template and the gitignore
guard.

**Files:**
- Create: `bin/dev`, `.env.example`
- Modify: `.gitignore`

- [ ] **Step 1: Determine the full set of dev env vars**

Run: `grep -n "System.get_env\|System.fetch_env" config/runtime.exs config/dev.exs`
List every var the dev runtime reads so `.env.example` is a complete template.
(Known: `GARAGE_ACCESS_KEY_ID`, `GARAGE_SECRET_ACCESS_KEY`, `GARAGE_HOST`,
`GARAGE_PORT`, `OPENROUTER_API_KEY`. Add any others the grep reveals that apply to
dev — do NOT invent vars that don't exist in config.)

- [ ] **Step 2: Write `.env.example`**

```
# OpenRouter (you provide your key)
OPENROUTER_API_KEY=

# Local Garage S3 — you CHOOSE these once; bin/garage-bootstrap.sh imports them.
# Key id must be GK-prefixed; secret a 64-char hex string. Generate e.g.:
#   GARAGE_ACCESS_KEY_ID="GK$(openssl rand -hex 13)"
#   GARAGE_SECRET_ACCESS_KEY="$(openssl rand -hex 32)"
GARAGE_ACCESS_KEY_ID=
GARAGE_SECRET_ACCESS_KEY=
GARAGE_HOST=localhost
GARAGE_PORT=3900
```
Add any additional dev vars found in Step 1 with blank/placeholder values.

- [ ] **Step 3: Write `bin/dev`**

```sh
#!/usr/bin/env sh
set -eu

# First run: seed .env and stop so the user fills in creds before anything uses them.
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

# Provision once / no-op on subsequent runs (imports .env creds, makes the bucket).
./bin/garage-bootstrap.sh

exec mix phx.server
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x bin/dev`

- [ ] **Step 5: Syntax-check**

Run: `sh -n bin/dev`
Expected: no output, exit 0.

- [ ] **Step 6: Add `.env` to `.gitignore`**

Run: `grep -qxF '.env' .gitignore || printf '\n# Local dev secrets\n.env\n' >> .gitignore`
Then confirm: `grep -n '^\.env$' .gitignore` shows a match. The ignore line MUST be
exactly `.env` (not `.env*`), so `.env.example` is still tracked. Verify the
template is visible to jj: `jj file list | grep -E '\.env(\.example)?$'` should
list `.env.example` and NOT `.env`.

- [ ] **Step 7: Commit**

```bash
jj commit -m "infra(garage): bin/dev one-command startup + .env.example + gitignore

bin/dev: seed/source .env -> docker compose up --wait -> bootstrap -> phx.server.
.env.example documents chosen GARAGE_* creds; .env gitignored.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: End-to-end bootstrap dry run (implementer-runnable, no app secrets)

Prove the compose + bootstrap path works against real Garage, using **throwaway
test creds** (NOT the user's real ones). This exercises everything except the
actual image upload (which needs the OpenRouter/image-gen client).

**Files:** none (verification only)

- [ ] **Step 1: Ensure Garage is up**

Run: `docker compose up -d --wait` then `docker compose ps`
Expected: `tore-garage` shows `healthy`.

- [ ] **Step 2: Run the bootstrap with throwaway creds**

```bash
export GARAGE_ACCESS_KEY_ID="GK$(openssl rand -hex 13)"
export GARAGE_SECRET_ACCESS_KEY="$(openssl rand -hex 32)"
./bin/garage-bootstrap.sh
```
Expected: prints `Garage bootstrap complete.`, exit 0.

- [ ] **Step 3: Verify the provisioning landed**

```bash
docker compose exec -T garage /garage key list
docker compose exec -T garage /garage bucket list
docker compose exec -T garage /garage bucket info tore-recipes
```
Expected: `key list` shows `tore-dev`; `bucket list` shows `tore-recipes`;
`bucket info` shows the `tore-dev` key has read+write.

- [ ] **Step 4: Prove idempotency — run the bootstrap again**

Run: `./bin/garage-bootstrap.sh`
Expected: prints `Garage bootstrap complete.` again, exit 0, no errors (layout
guard skips, key-list guard skips the import, bucket create/allow are no-ops).

- [ ] **Step 5: Tear down the throwaway state**

Run: `docker compose down -v`
Expected: containers + the `garage-meta`/`garage-data` volumes removed (so the
throwaway test key/bucket don't linger). `unset GARAGE_ACCESS_KEY_ID GARAGE_SECRET_ACCESS_KEY`.

- [ ] **Step 6: Confirm the app suite is untouched**

Run: `mix test`
Expected: **483 tests, 0 failures** (no code changed).
Run: `mix compile --warnings-as-errors`
Expected: clean.

No commit (verification only). If any step fails, fix the relevant file in its
task and re-verify before proceeding.

---

## Task 5: README "Local development" section + user smoke-check doc

Document the workflow and the one thing only the user can run (real image upload).

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a subsection under `## Getting started`**

Insert after the existing `mix setup` / `mix phx.server` block:

```markdown
### Local development with image storage (Garage)

Recipe images are stored in a local [Garage](https://garagehq.deuxfleurs.fr/)
(S3-compatible) instance, matching production.

```sh
bin/dev        # first run seeds .env and stops — fill it in, then re-run
```

`bin/dev` brings up Garage (`docker compose up -d --wait`), provisions the
`tore-recipes` bucket on first run, and starts Phoenix. Fill `.env` with:

- `OPENROUTER_API_KEY` — your OpenRouter key.
- `GARAGE_ACCESS_KEY_ID` / `GARAGE_SECRET_ACCESS_KEY` — credentials you choose
  (`GK`-prefixed id + hex secret; see the comments in `.env.example`). The
  bootstrap imports them into Garage.

Garage state persists in Docker named volumes — restarts reuse it. To wipe and
re-provision from scratch: `docker compose down -v` then `bin/dev` again.

Tests do not use Garage (they use an in-memory mock), so `mix test` needs nothing
running.
```

(Adjust the fenced-code nesting to render correctly in the README's existing
style.)

- [ ] **Step 2: Verify the README renders sensibly**

Run: `grep -n "Local development with image storage" README.md`
Expected: the new heading is present under Getting started.

- [ ] **Step 3: Commit**

```bash
jj commit -m "docs(readme): Local development with Garage image storage

Document bin/dev workflow, chosen GARAGE_* creds, and volume persistence.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Hand the user the one smoke check only they can run**

Report to the controller (for relay to the user) the manual end-to-end check that
needs the user's real OpenRouter key:

> With your real `.env` filled in: `bin/dev`, then in the app create a recipe that
> triggers image generation. Confirm the object landed:
> `docker compose exec garage /garage bucket info tore-recipes` shows >0 objects,
> and the recipe's `image_path` is an `http://localhost:3900/tore-recipes/…` URL
> that resolves in a browser.

---

## Final verification

After Task 5: `jj log -r 'master..@'` shows the five infra/doc commits; `mix test`
is 483/0; `docker compose config` parses; `sh -n bin/dev bin/garage-bootstrap.sh`
passes. Then use `superpowers:finishing-a-development-branch` to publish to master
(push directly; no workspace per project convention).
