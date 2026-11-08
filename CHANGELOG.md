# Changelog

All notable changes to Tore are recorded here. The app is pre-production, so
entries are grouped by feature milestone rather than released versions.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Pocket ID login

- Pocket ID is the only way to sign in. The 16-digit codes, the setup page, roles, the rate limiter and `argon2` are gone.
- Pocket ID decides who may sign in, through the groups on its client. A `tore_ai` claim marks who may use the server's LLM.
- Settings lists the members and has "Sign out", which also closes the app in other open tabs. Sessions last 90 days.
- A dev-only sign-in at `/dev/login` for working without Pocket ID.
- `docs/UI_SPEC.md` moved to `docs/specs/ui.md`, and `docs/LLM-NATIVE-FEATURES.md` to `docs/specs/llm-native-features.md`.

### Recipe proposals (plan 4)

- The planner can find recipe pages on the web, import one, or adapt a recipe from the catalog. Each becomes a proposal that a verifier checks and a person saves or discards on the run review page.
- LLM calls go through the `open_router` library instead of a hand-written adapter.

### Anticipation (plan 3)

- Long-press the tonight card or a grocery row for a sheet with a command scoped to it.
- `resolve_slot` resolves a slot from plain words, without the LLM.
- The ambient scan and its predictions also landed here, and were removed again in the trim.

### Trim

Everything now has to pass one test: does it change what Tore does next, without the household having to
maintain it? `SPEC.md` records this as a core rule, and each feature now has a status.

**Removed**

- The kiosk and device tokens, which nothing could issue, so the kiosk couldn't be used.
- Plan 3's predictions: the ambient scan, counter notes and their verifier, the 05:00 scan and the re-scan after edits. The long-press object sheets stay.
- The `/deals` page and the Coop stub. The planner reads deals, and stores moved to Settings.
- `/inbox`. Today's review pill opens the oldest pending review directly.
- The Saturday 18:30 prep job, whose result the page never looked up.
- Most of the cost page: tabs, charts, weekly bars and restaurant stats (1,104 lines down to 323).
- The unbuilt run kinds from `SPEC.md`.

**Changed**

- Receipts record cost only and never touch the pantry or the list, because a misread line would drop an item off the list.
- Shelf photos apply straight away with undo, and replace quantities.
- Eating out is a state of a day in the plan. It cancels any recipe, works on an empty day, and takes an optional place and amount.
- Stores are added by pasting a link, and the link picks the parser. Only https links on a parser's hosts get fetched.
- The household's language is chosen once at setup and then locked, and everything stored uses it.
- Prep is optional and on demand, through a "Prep this week" link on Plan.

**Added**

- Shelf life: the LLM guesses it per ingredient. It feeds belief, planning and the list, and a date set by hand teaches it.

**Fixed**

- The cost page no longer crashes when a background run finishes while it's open.
- Capture's replies, and 22 strings on other pages, appeared in English in a Swedish household. A test now fails on any empty or fuzzy Swedish string.
- Flaky database busy errors in tests, by using one connection.

### All-handlers Tiger-Style rename

The `Tore.Handlers.*Handler` family is retired — "handler" is filler; each
module now names what it does. Pure rename — suite unchanged at 483/0.

- Folded the context-backed handlers into their existing context modules:
  `RecipeHandler` → `Tore.Recipes`, `CostsHandler` → `Tore.Costs`,
  `PantryHandler` → `Tore.Pantry`, `DealsHandler` → `Tore.Deals`,
  `PrepHandler` → `Tore.Prep`. Their LLM/scraping/orchestration functions now
  sit beside the persistence and query functions they already called (the
  `Tore.Recipes` ↔ `RecipeHandler` cyclic dependency dissolves into local calls).
- `PlanningHandler` → `Tore.Planning` and `GroceriesHandler` → `Tore.Shop`:
  the bare context module is the imperative shell over the pure aggregate
  submodules (`*.Decider/.Events/.State/.Commands`), matching the `Tore.Recipes`
  pattern. The aggregate and its operations now share one name.
- `InsightsHandler` → `Tore.Insights` (no sibling context existed).
- `Tore.Costs.log_dining_out/1` is kept (live callers) with the folded `/2`
  beside it; the handler's `to_decimal` was folded as a distinct
  `receipt_to_decimal` because the pre-existing `Tore.Costs.to_decimal` coerces
  `nil → 0` while the receipt path must pass `nil` through — reusing it would
  have silently changed behavior. `lib/tore/handlers/` is removed.
- Follow-ups deferred to keep this pass a pure rename (not done here):
  consider making `Tore.Recipes.scrape_and_create/2` private now that its only
  caller is internal; add `@spec`s to the folded functions; add a comment on
  `Tore.Costs.receipt_to_decimal` documenting its nil-pass-through contract.

### Harness foundation

The event-sourced run harness — the load-bearing primitives for AI-driven
runs.

- `Tore.Harness.Run` aggregate: closed `Events`/`Commands` sum types (10 each),
  a six-variant `State` ADT enforced by `@enforce_keys`, and a pure
  `Decider` (`decide/2` + `evolve/2`).
- `Tore.Harness.Run` public surface: `load/1`, `next_stream_id/0`, and
  `append/3` (PubSub-broadcasting on the household topic).
- Closed `Artifact` behaviour + compile-time `Registry`, with the `PlanDiff`
  (events authoritative, `summarise/1` projection) and `RunSummary`
  (outcome + counts rollup) artifacts.
- `Tore.Harness.Orchestrator`: composes the Decider, owns persistence and
  artifacts, drives the planner command run.
- Per-household `Tore.Harness.Projector` (GenServer + ETS, replays open runs on
  boot) with its Registry and DynamicSupervisor.
- `Tore.LLM.PlannerAgent.run/4` refactored to a pure bounded tool-calling loop
  (no persistence, no correlation-id generation).
- `ai_operations`: `correlation_id` replaced with `run_stream_id` (irreversible
  migration).
- Web: `ReceiptLive` component (pattern-matched per `State` variant); `PlannerLive`
  consumes the Projector and renders the receipt, replacing the old
  `quick_reply` machinery.

### Real PlanDiff from tool outcomes

The receipt now reflects what the planner actually did, not a placeholder.

- `Tore.Harness.PlanDiffBuilder` reconstructs a real `PlanDiff` from the
  planner's successful tool calls (joining args to results by `tool_call_id`,
  keeping only successful action calls); the Orchestrator uses it instead of a
  hardcoded placeholder.
- New `PlanDiff` event types `RecipeSwapped` and `ServingsChanged` in the
  rollup; humanized `RunSummary`/`PlanDiff` change wording.
- Action tools require a `rationale` arg (flows into each diff event);
  `assign_recipe`/`swap_recipe` return the recipe label.
- `PlanningHandler.swap_slots/3`: a true atomic recipe swap (reads both slots
  before cross-assigning) — fixes a data-loss bug where the old move-based swap
  destroyed the target recipe.

### Named receipt lines + Swedish i18n

- The receipt's applied body renders one localized line per change, naming the
  recipe and day (from the `PlanDiff` rollup), e.g. "Bytte in Ugnsraggmunk på
  Lördag" / "Hoppade över Söndag".
- Plan-health badge localized via `{status, count}` + a view-side `gettext`
  helper (domain module stays web-free).
- Full Swedish translation pass: all remaining UI strings translated, 8 wrong
  fuzzy auto-matches corrected.
- Receipt component tests pinned to the `sv` locale so they assert what users
  actually see.

### Orchestrator error boundary

- `dispatch/2` is railway-oriented end to end with a typed error channel
  (`{:step_failed, term} | {:run_crashed, Exception.t}`): interior helpers
  thread `{:ok,_} | {:error,_}` (no more bare matches that raised), a
  `try/rescue` at the boundary converts any crash, and a best-effort tee records
  the run as `Failed` on any error — no dangling open runs.
- The receipt translates `failure_code` (machine-readable) instead of a baked
  message string; Swedish failure messages added.

### Verify-then-mutate planner + PlanVerifier

The planner is now verify-then-mutate, closing the load-bearing §A.5 atomicity
gap: the LLM proposes, a deterministic verifier decides, and a failure leaves
the plan genuinely unchanged.

- Planner action tools are pure: they propose plan changes against an in-memory
  working `Planning.State` via the existing `Planning.Decider` (preserving the
  model's mid-loop `:slot_empty`/`:not_pinned` feedback) and return the events
  they'd produce plus the evolved state — no persistence. `swap_recipe` reuses
  an extracted pure `PlanningHandler.swap_events/3`.
- `PlannerAgent` threads a `working_plan` through its loop and accumulates
  `plan_events`, returning both in its `loop_outcome`. The Orchestrator loads the
  plan into the agent context and persists the accumulated events exactly once,
  after the loop, via `PlanningHandler.apply_events/2`.
- `Tore.Harness.Verifier.PlanVerifier` — deterministic gate over the planner's
  `PlanDiff` (pinned slot unchanged, every assigned recipe has servings, skips
  are explicit, leftovers point to an earlier source meal, no banned/allergen/
  disliked ingredient). First failure wins. The repeat-window check is deferred
  (it needs a `repeat_window` household preference — a product decision; faking a
  default would be less correct than not checking).
- The Orchestrator gates the plan apply on the verifier: pass → apply + commit;
  fail → record the run as `Failed` with a structured `code` and an
  `{:edit_plan, slots}` repair action, applying nothing. A verifier failure is a
  successful dispatch of a failed run, not an infrastructure error.
- Web: the receipt renders a per-code, localized (en/sv) failure message and an
  "Edit the plan" link; the planner reads a `focus` query param and highlights
  the offending slot(s), completing the repair loop.

### Context capsules (§A.4)

The junk-drawer system prompt is replaced by typed, per-run-declared context
capsules — the model's standing context is now auditable ("what did the model
see?" = the run's capsule list), independently testable, and free of ambient
string concatenation.

- `Tore.Harness.Capsule` behaviour (`build/1` + `to_prompt/1`) and
  `Tore.Harness.Capsules.compose/2` — the only assembler; a capsule a run did
  not list is not in its prompt.
- Four capsules with a real consumer today, each a typed struct that fetches and
  summarises its own data (the compactness rule lives in the capsule):
  `HouseholdPreferencesCapsule`, `ActiveInsightsCapsule` (≤5),
  `WeekPlanCapsule` (typed per-day status), `PantryBeliefsCapsule`
  (names capped at 20 + a count).
- The planner run and the chat handler now declare their capsule list and
  compose it; the date and active week-mode stay as small inline framing. The
  planner's doubled role section (its own preamble plus the chat role text) is
  removed.
- `Tore.Chat.SystemPrompt.build/0` deleted — fully replaced by capsules.

### Weekly auto-planning (`:weekly_planning_run`, PlanMyWeek)

A headless harness run that fills the upcoming week's empty, unpinned dinner
slots, triggered by the Saturday cron.

- `:weekly_planning_run` reuses the planner's pure tool loop, the four context
  capsules, and `PlanVerifier`, via an extracted `run_planner_loop` helper shared
  with `:planner_command_run` (the planner clause is a behaviour-preserving
  refactor over the new `run_dispatch` + `run_planner_loop` helpers). Higher loop
  caps (10 round-trips / 25 action calls). Fills empty + unpinned slots only;
  pinned and assigned days are left untouched; the apply is atomic
  (verifier-gated).
- `PlanningHandler.plan_upcoming_week/0` is the cron entry; the Saturday 18:00
  Quantum job now targets the upcoming (next Mon–Sun) week via the harness. With
  no LiveView session the filled week surfaces through the Projector when the
  user next opens `/plan`; they edit individual slots with the existing modal.
- Removed the old one-shot `generate_plan` path — `PlanningHandler.generate_plan/3`,
  `Planning.Commands.GeneratePlan`, `Planning.Events.PlanGenerated` (whose evolve
  clobbered pins), the `@llm.generate_plan/1` callback + adapter impl, the
  `:generate_plan` SpendGuard entry, and the Prep page's "generate plan" button.
  The prep *guide* (`PrepHandler.generate_guide`) is independent and unchanged.
  The `feature_label("generate_plan")` Settings clause is kept — it labels
  historical `ai_operations` cost rows, not a live caller.

### Capture / Shop vocabulary rename

Aligned code with the SPEC's adopted UI vocabulary.

- `Tore.Chat.ChatHandler` → `Tore.Capture.Conversation` (`handle_text/2` →
  `reply/2`); `ChatLive`/`KioskChatLive` → `CaptureLive`/`KioskCaptureLive`;
  routes `/chat` → `/capture`, `/kiosk/chat` → `/kiosk/capture`. The dead
  `Tore.Chat.WeekContext` (superseded by `WeekPlanCapsule`) is deleted, retiring
  the `Tore.Chat` namespace.
- `Tore.Groceries` aggregate → `Tore.Shop`; `GroceryLive` → `ShopLive`; route
  `/groceries` → `/shop`; event-store stream key `grocery_list:` → `shop_list:`
  and the PubSub topic `grocery_list` → `shop_list`; nav label → "Shop"/"Inköp".
  The grocery-list aggregate and its surface now share one name.
- Kept: `Tore.Handlers.GroceriesHandler` (a Tiger-Style rename of the whole
  handler family is a separate spec) and the cross-feature grocery vocabulary
  (`GroceryDiff`, `GroceryVerifier`, `resolve_grocery_item`,
  `:grocery_reconciliation_run`, `:grocery_checkoff`) — those name the grocery
  domain concept used by other features, not the Shop surface.
- SPEC.md line 69 + module map updated to match (overriding the earlier "stream
  stays named groceries" note; safe pre-production with no persisted events).

### Fixed

- Event-store JSON round-trip downgraded atom/Decimal event fields on replay;
  `Run.load` now rehydrates them (`cost_usd` → Decimal; `phase`/`surface`/
  `step_kind` and `RunSummary` outcome/count keys → atoms via explicit closed
  maps, load-order independent to survive cold-boot Projector replay).
- `PlannerAgent` assigned a unique `step_index` per trace entry (was colliding,
  violating the `ai_operations` unique constraint) and coerces a float
  `cost_usd` from the LLM into a Decimal.
- Planner dispatch in `PlannerLive` clears the spinner and flashes on failure
  instead of hanging on a silent crash.
- `FailureRecorded` round-trip: `repair_action` is encoded as a map on write and
  decoded back to `{:edit_plan, slots}` via a literal map on read, and
  `failure_code` decodes via a literal map for the known verifier codes — both
  cold-boot safe (no `String.to_existing_atom`), so a fresh Projector boot can't
  downgrade a verifier code to a string the receipt would fail to match.
