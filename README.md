# Tore

![tore](priv/static/images/logo.svg)

An AI-assisted meal planner built with Phoenix LiveView — named as a homage to [Tore Wretman](https://sv.wikipedia.org/wiki/Tore_Wretman), the father of modern Swedish cuisine.

---

## What it does

- **Opens where you need it** — the app opens on the screen you most likely want now, such as tonight's dinner, the list on Saturday morning or next week's plan on Sunday evening, picked ahead of time by a decision model. A chat box with a few suggested next steps sits at the bottom of every screen, and a menu lists every page.
- **Weekly meal planning** — fills open dinners on Saturdays from your recipe catalog, respecting the pantry, current deals and what it remembers about your household. Tell it what to change in plain words, or tap. It can also find a recipe on the web or adapt one of yours, for you to save or discard.
- **Recipes** — import from a link or a photo, review before it's saved, and browse your collection. Recipes come in your household's language.
- **Pantry as a belief** — Tore keeps a rough idea of what you have from checked-off groceries, shelf photos and what you tell it. It guesses shelf life, and uses that in planning and on the list.
- **Shopping list** — built from the week's plan, aggregated by ingredient. Adding by hand always works.
- **Capture** — send text or photos. A photo can be a receipt, a recipe, a shelf or your fridge. Most changes it makes come with Undo, and it can delete a recipe, a receipt or a shopping item when you ask.
- **Household memory** — a short profile and notes Tore keeps about how you eat, from what you tell Capture and a weekly look at the plan. You can read and remove entries in Settings.
- **Deals** — add a store by pasting a link to its offers; the planner reads them. ICA only so far, and the fetch has known problems (see `SPEC.md` §8).
- **Costs** — one page with the month's total, recent receipts and eating out.
- **Eating out** — mark a day and it cancels the recipe, with an optional place and amount.
- **Prep guide** — optional, on demand, from the week's plan.
- **Language** — chosen once for the household, with a full Swedish UI through Gettext.
- **Several households** — friends can share one server, each in a household of their own. Members add each other by Pocket ID username, and someone in two households switches in Settings. Nothing crosses households except deals.

---

## Tech stack

| Layer | Choice |
|---|---|
| Framework | Phoenix 1.8, LiveView |
| Database | SQLite via Ecto + Exqlite |
| LLM / vision | OpenRouter (configurable model per use-case) |
| Image generation | OpenRouter image model |
| Structured outputs | OpenRouter `json_schema` response format |
| Markdown rendering | MDEx (CommonMark, Rust NIF) |
| Scheduling | Quantum |
| Auth | [Pocket ID](https://pocket-id.org) over OIDC, through `oidcc` |

---

## Architecture

```
lib/
├── tore/
│   ├── accounts/         # Users, signed in from Pocket ID claims
│   ├── auth/             # Pocket ID sign-in (OIDC with PKCE)
│   ├── adapters/         # Req HTTP adapter, image stub
│   ├── image_gen/        # Recipe images through the open_router library
│   ├── capture/          # Capture: the LLM router, its tools, uploads
│   ├── costs/            # Receipts, line items, LLM usage
│   ├── deals/            # Deal schema, store configs, one parser per chain
│   ├── harness/          # Runs: the runs table, kinds, artifacts, capsules, verifiers, undo
│   ├── household/        # Household, preferences, memory
│   ├── llm/              # LLM facade, prompts, planner agent and tools
│   ├── pantry/           # Pantry beliefs and expiry
│   ├── planning/         # Weekly plan decider (event-sourced), commands, events, state
│   ├── prep/             # Prep guides
│   ├── recipes/          # Recipe, Ingredient (with canonical keys), Tag
│   └── shop/             # Shopping list decider (event-sourced)
└── tore_web/
    ├── components/       # Core UI components, layouts
    ├── controllers/      # Session, review, images, error controllers
    ├── live/             # LiveViews (home, planner, capture, shop, recipe, settings, …)
    └── plugs/            # Auth, locale
```

### Key patterns

**Event sourcing** — planning and shopping list state are derived from an append-only event log (`Tore.EventStore`). The `Decider` pattern: `decide(command, state) → events`, `evolve(state, event) → state`.

**Harness** — every state-changing AI action is a run, one row in the `runs` table: pi proposes through an MCP tool, a pure verifier checks, the change applies in one transaction with its undo, and you get a receipt. A kind of run implements `Tore.Harness.Kind`, and `Tore.Harness.Runs` drives it. See `SPEC.md` §A.2.

**Context modules** — LiveViews call contexts such as `Tore.Planning` and `Tore.Shop`, which orchestrate DB reads, pi jobs and PubSub broadcasts. Each function that touches a household's data takes a `%Tore.Scope{}` first, and `Tore.Repo` raises on a household table queried without one.

**Strict MCP** — Tore writes no prompts. Every AI task is pi working through Tore's `/mcp` tools: the person's chat, which the screens' sheets also ask, or a background job from `harness/tasks/*.md` (`Tore.Agent`). A new AI feature is a tool, a task file or a line in `harness/AGENTS.md`.

**The gate** — `Tore.Pi.check/1` refuses a household nobody sponsors, and one that has spent its monthly limit; each pi session records its cost per household. The monthly limit is what stops a runaway loop draining API credits.

**Canonical ingredient keys** — ingredients store a `key` column (e.g. `gul_lok`) derived from the display name. Used for deduplication, pantry matching, and grocery aggregation across locales.

---

## Getting started

```sh
mix setup          # install deps, create and migrate DB, seed
mix phx.server     # http://localhost:4000
```

Every AI request goes through [pi](https://github.com/badlogic/pi-mono) (`Tore.Pi`), started by
`harness/pi-session`, which needs `jq`, `pi` and a model key (`ANTHROPIC_API_KEY` or
`OPENROUTER_API_KEY`) in its environment. Without `TORE_PI_COMMAND` Tore still runs, in dev and
production, with every AI feature off.

```sh
TORE_PI_COMMAND=harness/pi-session           # or an ssh command to the harness machine
TORE_PI_MCP_URL=http://localhost:4000/mcp    # /mcp as pi reaches it (default: the endpoint's)
TORE_PI_MODEL=anthropic/claude-sonnet-5-5    # the chat and background jobs
TORE_PI_LIGHT_MODEL=anthropic/claude-haiku-5-5  # the home pick and learning names
```

Recipe pictures are drawn by an image model through OpenRouter: set `OPENROUTER_API_KEY`, and
optionally `OPENROUTER_IMAGE_MODEL` (default `microsoft/mai-image-2.6`). The same key lets Jev
(`typesafe/jev-1.14`) guess which of the week's offers a household wants.

Dates and times such as "today" and "Saturday morning" use the server's local clock (`Tore.Clock`), so set `TZ` to the household's time zone.

### Signing in with Pocket ID

Tore has no passwords of its own. In Pocket ID:

1. Create a `tore` group for everyone who may use Tore, and a `tore-ai` group for those who may use
   the server's LLM. Give `tore-ai` the custom claim `tore_ai` with the value `true`.
2. Create an OIDC client for Tore, allowed only for the `tore` group, with the callback
   `http://localhost:4000/auth/oidc/callback` (and `https://<your host>/auth/oidc/callback` in production).

Then set:

- `OIDC_ISSUER` — your Pocket ID URL, for example `https://id.example.com`.
- `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` — from the client.
- `OIDC_REDIRECT_URI` — production only, if it isn't `https://$PHX_HOST/auth/oidc/callback`.
- `AI_CLAIM` — optional, the claim that grants LLM access (default `tore_ai`).

To let a friend in, create their Pocket ID user and add them to `tore`. At their first sign-in they join
every household that already added their username, or else get a household of their own and pick its
language. A household has AI when a member in `tore-ai` lets it use their credits; someone in `tore-ai`
who starts a household sponsors it automatically. To share a household, add the other person's Pocket ID
username in Settings.

Production refuses to boot without the first three. In dev they're optional: without them, `/login`
offers a dev sign-in instead.

### Local development with image storage (Garage)

Recipe images are stored in a local [Garage](https://garagehq.deuxfleurs.fr/)
(S3-compatible) instance, matching production. Requires Docker with the Compose
plugin.

```sh
bin/dev        # first run seeds .env and stops — fill it in, then re-run
```

`bin/dev` brings up Garage (`docker compose up -d --wait`), provisions the
`tore-recipes` bucket on first run, and starts Phoenix. Fill `.env` with:

- `OPENROUTER_API_KEY` — your OpenRouter key, for recipe pictures and Jev's offer guesses.
- `GARAGE_ACCESS_KEY_ID` / `GARAGE_SECRET_ACCESS_KEY` — credentials you choose
  (`GK`-prefixed id + 64-char hex secret; see the comments in `.env.example`).
  `bin/garage-bootstrap.sh` imports them into Garage.

Garage state persists in Docker named volumes, so restarts reuse it. To wipe and
re-provision from scratch: `docker compose down -v`, then `bin/dev` again.

Tests use an in-memory storage mock, so `mix test` needs nothing running.

---

## Running tests

```sh
mix test
```

No external dependencies required (LLM and HTTP are mocked in test).
