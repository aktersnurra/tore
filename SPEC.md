# Tore — AI-Native Meal Planner

> *Tore* is a self-hosted family meal planner. The previous incarnation was *Scullion*,
> a competent but conventional CRUD-shaped planner. This document specifies the
> AI-native rewrite. Where this spec disagrees with the codebase, one of them is
> a bug: reconcile deliberately and record the decision in §Status. Neither side
> silently wins.

## Status

- **Source-of-truth date:** 2026-11-10
- **2026-05-31:** Reversed the Family→Household naming. `Tore.Household` is canonical; `Tore.Family.*` deleted.
- **2026-06-02:** Added §Agent Harness Layer. Tore is reframed as a household food-operations harness; every state-changing AI action is a `KitchenRun` producing typed artifacts, verified deterministically, applied atomically. §The Six LLM-Native Features rewritten in harness terms. Future sub-specs implement the harness primitives, verifiers, capsules, risk tiers, resolved references, and Kitchen Skills.
- **2026-06-02:** UI/UX vocabulary adopted. Canonical names: `CounterNote` (artifact and code module — replaces the working name `Opportunity` from the first draft of §A), `Shop` (UI surface and route `/shop` — replaces `Groceries` / `/groceries`), `Capture` (UI surface and route `/capture` — replaces `Chat` / `/chat`), `Tore.Capture` (module namespace — replaces `Tore.Chat`). The code rename is a separate sub-plan; SPEC.md uses the new names throughout from this commit forward.
- **2026-07-03:** Reconciliation pass. Absorbed what the run-receipts slice (`docs/specs/run-receipts.md`) and a month of implementation legitimately decided: the run aggregate is event-sourced (`Tore.Harness.Run`), a seventh `:discarded` terminal state with a weekly TTL sweep, `undo_payload` as a sum type replacing `undo_ref`, the `PantrySnapshot` / `RunBundle` artifacts, and the `:capture_turn_run` parent-run kind. Fixed internal contradictions (SystemPrompt, fridge-rescue tier, weekly planning Pattern A vs B, leftover Chat naming, Quantum jobs bypassing the harness). Made the single-household deployment assumption explicit. Decided: Capture keeps LLM photo classification (`classify_image`) rather than explicit intent chips — considered and rejected the chips.
- **2026-07-12:** §A.6.2 resolved-handles landed for plan slots. Decided: handles carry an opaque `ref` token (not the struct) to the model; the PlannerAgent runtime exchanges refs for real IDs at the action-tool boundary via a per-run registry, and rejects invented/stale refs as a tool error without invoking the tool. Added `:direct_touch` as a `source` value (confidence 1.0 — the user touched the object in the UI, nothing to resolve). Shipped: `resolve_recipe`, direct-touch slot handles from the plan slot sheet's scoped command input. Deferred: `resolve_slot`, `resolve_grocery_item`, `resolve_pantry_item` — until their consumers exist. Slot action-tool params stay structural `slot_key` domain keys by design, not a `ResolvedSlot` ref.
- **2026-08-04:** Anticipation layer landed (plan 3 of 3). `CounterNote` gained a `proposed_run` map column (sum type: `planner_command` | `add_item` | `nil`) and four scan kinds (`swap_suggestion`, `freezer_fallback`, `missing_ingredient`, `usual_item_missing`); `CounterNoteVerifier` checks every scan proposal before it is materialized. A new `:ambient_scan_run` (Tier 0, `started_by: "system"`) predicts at most one actionable note per surface daily at 05:00 and after a 5-minute-debounced plan/shop mutation, gated by SpendGuard `:ambient_scan {8_000, 600}`; `CounterNotes.recently_ignored/1` feeds dismissed notes back into the next scan prompt so the model does not re-propose them. `CounterNotes.follow_up/2` is the single accept-with-effect path: `add_item` applies directly (no LLM), `planner_command` dispatches `:planner_command_run` with `started_by: "counter_note_followup"` and Plan 2's `scoped_slot` machinery. Home hero, the Plan slot sheet, the Shop add-field, and the Capture tray's half state all render these notes as one-tap predictions per Rule 1 (replace generic affordances, never add elements) — never awaited on page load (Rule 2). §A.6.2: `resolve_slot` shipped as a pure, deterministic resolver — see below. Also shipped: long-press object sheets on the tonight card (scoped to today) and grocery rows (scoped via a `Capture.Router` text referent, since no grocery action tools exist yet to consume a handle).
- **2026-09-06:** Recipe proposals landed (plan 4). The planner can find recipe pages on the web (`find_recipe_web`), import one (`import_recipe_from_web`) or adapt a catalog recipe (`generate_recipe_variant`). Each ends the loop with a `RecipeProposal` that `RecipeProposalVerifier` checks, parked in `:needs_user` until a person saves or discards it on the run review page. The hand-rolled OpenRouter transport was replaced by the `open_router` library.
- **2026-11-06:** Trim. New core rule: the upkeep test (§Core Philosophy). Removed the kiosk and device tokens, counter notes, `/inbox`, the `/deals` page, the Saturday prep job, and the unbuilt run kinds `:deal_capture_run`, `:grocery_reconciliation_run`, `:prep_generation_run` and `:recipe_generation_run`. `:fridge_rescue_run` was never built either: the Capture tool that replies with suggestions is all there is. Receipts now record cost only and never touch the pantry, because a misread line would drop an item off the shopping list. Shelf photos apply straight away with undo and replace quantities. Added shelf life, stores added by link with a parser per chain, one cost page, and eating out as a meal state. The household's language is chosen once at setup and then locked. §The Six LLM-Native Features became §Features, with a status on each. The anticipation layer waits for Plan 3's rewrite (§3).
- **2026-11-08:** The trim was rebased onto plans 3 and 4, which it had not been based on. Cut by the owner: the ambient scan, `CounterNote`s, `CounterNoteVerifier`, the debouncer and the 05:00 scan. Kept from plan 3: the long-press object sheets and `resolve_slot`. Plan 4 stays whole.
- **2026-11-08:** Pocket ID is the only login. Removed the 16-digit codes, the setup page, roles, the rate limiter and `argon2`. Pocket ID decides who may sign in through the groups on its client, and a `tore_ai` claim marks who may use the server's LLM. Settings lists members and has "Sign out". `docs/UI_SPEC.md` became `docs/specs/ui.md`, and `docs/LLM-NATIVE-FEATURES.md` became `docs/specs/llm-native-features.md`.
- **2026-11-09:** Several households share one server (`.docs/specs/households.md`). Every function that reads or writes a household's data takes a `%Tore.Scope{}` first, and `Tore.Repo` raises on a household table queried without one. People belong to households through memberships, one active at a time; a first sign-in either joins the households that added that username or starts a household of its own, whose language is picked once at `/welcome`. Stores are shared and fetched once; deals are the only data that crosses households. `Tore.LLM` is the gate for LLM calls (image generation still calls OpenRouter directly, after a gated call): a household needs a sponsor with the `tore_ai` claim, the server needs an OpenRouter key (now optional), and each household has its own monthly limit. A friend's own OpenRouter key is a non-goal, so it left the backlog.
- **2026-11-10:** Run core (`.docs/specs/run-core.md`) and household memory (`.docs/specs/household-memory.md`). A `runs` table (`Tore.Harness.KitchenRun`) replaces the event-sourced run aggregate, its Projector, `UndoPayload` and `RunReceipts`. A kind of run is a plain behaviour (`Tore.Harness.Kind`) that `Tore.Harness.Runs` drives, and undo is a list of steps captured when the run applies. `PantrySnapshot`, `RunBundle`, `RunSummary`, `MemoryUpdate`, `:capture_turn_run` and `:kitchen_memory_synthesis_run` are gone. Household memory, a bounded profile and notes the household shares, replaces insight synthesis. All of Capture's writes now go through runs, which closes the gap §A.2 recorded on 2026-11-06, and Capture gained a `memory` tool. Then a simplification pass, by the owner's rule: keep the data model simple, and give the agent plain tools instead of building machinery for rare cases. An eating-out day's place and amount live on the plan, and the `dining_out` table is gone. Undoing a check-off leaves its pantry addition. The database holds one pantry row per ingredient. Capture deletes recipes, receipts and shopping items directly, with no review or undo. Undo puts things back as they were before the run, even over a later change.
- **Supersedes:** the original Scullion SPEC.md (2026-05-02), now archived in git history at commit `af0ad48`.
- **Companion docs:** `docs/specs/llm-native-features.md` (the design brief this spec absorbs), `docs/specs/ui.md` (UI/UX contract — meets this spec at the artifact boundary), `docs/specs/run-receipts.md` (the first vertical slice of the harness: receipts, diffs, undo; its run model is superseded by run core, §A.2). Per-feature design notes live under `docs/specs/`.
- **Naming:** the project is *Tore*. Any remaining reference to Scullion or Family in code is legacy and slated for deletion (see §Removed in Rewrite).

---

## Core Philosophy

Three sentences govern every decision in this spec:

1. **The system has a good guess and makes it easy to say yes or make a small correction.** The LLM does the work. The user approves, ignores, or nudges.
2. **The system should be more wrong about your kitchen and more right about your life.** Pantry counts will drift. Receipt scans will be skipped. But the system can learn that you skip Thursdays, that fish on weekdays doesn't stick, and that ICA has pork on sale — and that's the value.
3. **Does it change what Tore does next, without the household having to maintain it?** This is the upkeep test, and every feature has to pass it. Tore stays advanced: predictive, learning, doing the work unprompted. What goes is a report nobody acts on, a chore, or code nothing can reach.

Derived rules:

- **Skipping is first-class and neutral.** One tap. No "why?", no cascade warning. The plan is a proposal, not a contract.
- **No nagging.** No notifications about logging, no streaks, no reminders. The app is ready when you come to it.
- **The grocery list is the reliability anchor.** It works even if everything else is chaos. Manual add always works.
- **Trust the user's choices.** When the user overrides a suggestion, the app does not ask why. It notes the event and moves on.
- **Surface, never push.** Proactive intelligence appears in the UI when you open the app. It never sends a notification.

---

## One Interface, One Backend

```
┌──────────────────────┐         ┌──────────────────────────────────┐
│  Phone / laptop      │         │  VPS                             │
│  Browser ──────────────HTTPS──▶  Phoenix + LiveView               │
│  Pocket ID sign-in   │         │  Ecto + SQLite                   │
└──────────────────────┘         │  OpenRouter (LLM + vision)       │
                                 │  Garage (S3) for images          │
                                 │  Quantum scheduler               │
                                 │  EventStore (planning, groceries)│
                                 └──────────────────────────────────┘
```

All logic runs on the server.

---

## Pattern Strategy

Two aggregates are event-sourced via the Decider pattern. Everything else is Ecto CRUD
behind a context boundary. LiveViews call context APIs only; the context modules orchestrate IO.

### Event-sourced

| Aggregate     | Why                                                                |
|---------------|--------------------------------------------------------------------|
| **Planning**  | LLM-orchestrated workflow with frequent user tweaks. Its events are what the weekly memory review learns from (§1). |
| **Shop** | Multi-user real-time grocery checklist (decider streams `shop_list:<household>:<monday>` from `Tore.Streams`, formerly `groceries`). Granular events enable PubSub sync and natural undo. |

### CRUD

| Context       | Role                                                              |
|---------------|-------------------------------------------------------------------|
| **Accounts**  | Users, sessions, per-user prefs.                                  |
| **Household** | Shared household-level state (preferences, memory, members). |
| **Recipes**   | Reference catalog.                                                |
| **Deals**     | Scraped weekly from stores added by link, expire automatically.   |
| **Pantry**    | Approximate inventory. **No primary management UI.** See §Pantry. |
| **Costs**     | Receipts, for cost tracking; eating out is read from the plan (§7). **Not in main nav.** |
| **Runs** (`Tore.Harness.Runs`) | One `runs` row per `KitchenRun`, moved through its steps by pure transitions (§A.2). Replaced an event-sourced run aggregate on 2026-11-10. |
| **Prep**      | LLM-generated text guides, on demand. Optional. Read-only.        |
| **AIOperations** | Low-level audit log of every LLM call with correlation IDs, step index, model, and token usage. Each `KitchenRun` owns its rows by correlation ID. |

---

## Agent Harness Layer

### A.1 — Tore is a household food-operations harness

Tore is not a chatbot over meal-planning data. Tore is a small, tasteful harness
around the household food loop.

A coding agent feels powerful because it doesn't just answer — it runs a bounded
operation, produces a diff, verifies it, and lets you accept or reject. The model
is one component of a larger scaffold: typed context, permissioned tools,
structured prompts, execution traces, verification, and reversible state. The
harness is what turns "chat with file access" into something a careful engineer
will trust.

Tore applies the same shape to food. Every non-trivial AI action is a bounded
run with a typed input snapshot, declared context, permissioned tools, generated
artifacts, deterministic verification, and a clean reversible diff. The LLM
proposes. The harness verifies. The user sees a quiet, tasteful receipt — not a
transcript.

The rest of this section names the parts of that harness: runs, artifacts,
capsules, verifiers, risk tiers, resolver tools, skills, inspectability, and
model routing. Every built feature in §Features below is then
described as a kind of run.

### A.2 — The unit is a `KitchenRun`

Every non-trivial AI action in Tore is a `KitchenRun`. A run is the food
equivalent of an agentic coding session: a bounded operation with a typed
beginning, a verified middle, and a reversible end. `AIOperations` continues
to record the low-level LLM-call audit log; a single `KitchenRun` owns one or
more `AIOperations` rows tied by `correlation_id`.

`KitchenRun` is both the concept and the code: `Tore.Harness.KitchenRun` is one row
in the `runs` table, and `Tore.Harness.Runs` moves it through its steps. A kind of run
is a module implementing the `Tore.Harness.Kind` behaviour.

**Fields** (columns on `runs`):

- `id`: `"run-<base64>"`, which keeps `/runs/:id` links
- `household_id`, `user_id`
- `kind`: the kind's name, such as `"planner_command_run"` (see §Features)
- `actor`: `:user | :system | :mcp`
- `surface`: `:today | :plan | :shop | nil`, declared by the kind
- `status`: `:running | :needs_user | :applied | :failed | :reverted | :discarded`
- `phase`: while `:running`, one of `:gathering_context | :proposing | :verifying`. Drives the UI's thinking-state strip (docs/specs/ui.md §7.2): *"Checking the week…", "Verifying changes…"*
- `input`: the JSON the run started with, string keys only
- `artifacts`: the typed `RunArtifact`s (see §A.3). A run waiting for review stores its proposal here
- `question`: what a `:needs_user` run asks
- `failure_code`, `repair_action`: why a run failed and what the person can do (§A.5). A `failure_message` column exists, but nothing writes it yet
- `discard_reason`: `:user_discarded | :ttl_expired`
- `undo`: set when the run applies, either `{:steps, [step]}` or `{:irreversible, reason}`
- `prompt_tokens`, `completion_tokens`, `cost_usd`: the usage `propose` returned
- `opened_at`, `applied_at`, `reverted_at`, `closed_at`

CHECK constraints tie the columns to the status: an applied run has `applied_at` and
`undo`, a failed one a `failure_code`, a `:needs_user` one a `question`. The LLM calls
stay in `ai_operations`, keyed by the run's id.

**Steps.** A kind says what each step means for it:

| Step | May do | May not do |
|---|---|---|
| `propose` | LLM (through `Tore.LLM`), reads | write domain state |
| `resolve` | LLM, reads (for example canonicalising pantry names) | write domain state |
| `verify` | nothing: a pure check | any effect |
| `apply_proposal` | database writes, in one transaction with the status change | LLM, HTTP, storage |
| `after_commit` | best-effort effects, such as broadcasting or deleting a photo | |

`Runs.start/3` runs every step. `Runs.submit/4` takes a ready proposal and skips
`propose`: Capture's typed edits use it, and MCP writes will. A kind's `review_question/1`
says whether a person must look first. If so, the run waits in `:needs_user` with its
proposal, and `Runs.confirm/3` verifies the edited proposal again before applying it.
`apply_proposal` may return `{:fail, code, repair}` when a check no longer holds inside
the transaction, which fails the run as a verifier would.

**Status transitions** (`Tore.Harness.KitchenRun.Transition`, pure):

| From | Action | To |
|---|---|---|
| `running` | `phase` | `running` |
| `running` | `ask`, `review` | `needs_user` |
| `running` | `apply` | `applied` |
| `running` | `fail` | `failed` |
| `needs_user` | `confirm` | `applied` |
| `needs_user` | `discard` | `discarded` |
| `applied` | `revert` | `reverted` |

Anything else is an error. `failed`, `reverted` and `discarded` are terminal. A failed
`confirm` leaves the run in `needs_user`, so the person can correct the card. An
irreversible run refuses `revert`.

A `:needs_user` run nobody answers is discarded by the person or by the weekly sweep
(`Tore.Harness.InboxSweeper`). Nothing was applied, so there is nothing to revert. Tore
runs on one BEAM node, so at boot every `running` row is dead, and
`Runs.fail_interrupted/0` fails it with `:interrupted`.

**Undo.** `apply_proposal` captures the before-image of what it touches, so the undo is
known when the run applies. The steps are `restore_plan_slots` (each touched slot and
pin, put back by appending planning events), `restore_pantry_item`, `restore_memory`,
`delete_receipt`, `delete_recipe`, `remove_shop_item` and `uncheck_shop_item`. Revert
runs them last first, in one transaction with the status change. An unknown step raises
and rolls back. Undo puts back what was there before the run, even over a later change;
it doesn't detect a stale undo. A delete or shop step whose target is already gone
counts as done. Building the shopping list is irreversible, since it replaces the list.

`{:run_changed, %KitchenRun{}}` is broadcast on `runs:household:<id>` after each commit.
Screens match on `status`.

**Hard rules.**

- Only a `KitchenRun` may write household state on the AI's behalf. The planner, the crons, Capture and (later) MCP all go through `Runs`.
- Every kind has a verifier: `verify` is a required callback.
- Two exceptions write directly, by decision. `mark_recipe_cooked` sets one timestamp. Capture's deletes (`delete_recipe`, `delete_receipt`, `remove_shopping_item`) do what the person asked for by name, so they get no review, receipt or undo (2026-11-10). A person tapping in a screen also writes directly.

### A.3 — Runs produce `RunArtifact`s, not chat output

A `KitchenRun` does not produce a conversational reply. It produces one or
more `RunArtifact`s — typed, renderable objects with a compact summary and an
inspectable detail view. Artifacts are the contract between the harness and
the UI: the harness emits them, the UI surfaces them, and neither side knows
how the other implements its half.

**Artifact kinds:**

| Kind | Produced by | Carries |
|---|---|---|
| `PlanDiff` | `:planner_command_run`, `:weekly_planning_run`, `:set_plan_slot_run`, `:plan_edit_run` | Per-slot changes with before-and-after recipe handles, and the planning events to append |
| `RecipeProposal` | `:planner_command_run`, when the planner imports a recipe from the web or adapts one; `:recipe_ingestion_run`, for a link or photo sent to Capture | A recipe that isn't saved yet, with its source, steps and an optional slot to fill. A person saves, edits or discards it |
| `PantryBeliefUpdate` | `:pantry_belief_update_run` | Items added or removed, each with `provenance` |
| `CostEntry` | `:receipt_ingestion_run` | Parsed receipt: store, date, total, line items, optional photo path |
| `MemoryBatch` | `:memory_review_run`, `:memory_update_run` | Add, patch and remove operations on one part of the household's memory (§1) |
| `ShopChange` | `:shop_edit_run` | An item added or checked off, or the week's list built |

A proposal is a registered artifact or a list of them, because a run waiting for review
stores it until it is confirmed.

**Rendering.** The UI reads artifacts and status, never a run's internals. Capture
shows each run as one short line built from its artifact, with Undo. The run review
page shows a waiting proposal (a `CostEntry` or a `RecipeProposal`) as a card the person
can edit. The `Artifact` behaviour still declares `summary/1` and
`is_rationale_complete/1`, which nothing has called since `RunSummary` went.

**No chat transcripts in artifacts.** The LLM's prose is recorded in `ai_operations` for
the audit log, never as an artifact.

**Hard rule.** An applied run carries the artifacts of what it changed, and a run that
changed nothing carries none. A run waiting for review carries its proposal.

### A.4 — Context capsules, not one big prompt

The pre-harness code assembled one big system prompt via
`Tore.Chat.SystemPrompt.build/0` — household preferences, active insights,
week context, and approximate pantry, all glued together. That builder is a
junk drawer by construction: every new feature adds another paragraph, every
prompt gets longer, and no caller can tell which inputs actually drove a
model's behaviour. It has been deleted; the rules below keep it deleted.

A `KitchenRun` receives a small set of named, typed **context capsules**.
Each capsule is compact, audited, and declared per run — never inferred from
the surrounding code, never assembled by string concatenation.

**Capsule catalog (V1):**

| Capsule | Provides | Source |
|---|---|---|
| `HouseholdPreferencesCapsule` | Dietary rules and allergies, the two `PlanVerifier` enforces | `Tore.Household.get_preferences/1` |
| `MemoryCapsule` | The household's profile and notes, with how full each is (§1) | `Tore.Household.Memory.snapshot/1` |
| `WeekPlanCapsule` | The current or referenced week's plan state, per slot | `Tore.Planning.load_plan/2` |
| `PantryBeliefsCapsule` | Approximate inventory with `last_seen_at` and provenance; framed as belief, not fact | `Tore.Pantry.list_inventory/1` |
| `DealsDigestCapsule` | Active deals grouped by store, ranked by household affinity | `Tore.Deals.list_current/1` + `RecipeAffinityCapsule` |
| `RecipeAffinityCapsule` | Recipes the household chose recently or repeatedly, plus those swapped or removed | derived from planning event stream |
| `RecentHistoryCapsule` | Last 4–6 weeks of meals, skipped slots, leftover cascades | derived from planning event stream |
| `CostIntentCapsule` | Monthly spend target, current month-to-date, recent overspend signal | derived from `Tore.Costs` + household preferences |

**Declaration rule.** Every run kind declares its capsules statically. A
capsule the run did not request is not available to its prompt — there is no
"ambient" context. This is auditable: looking at a run, you can answer
"what did the model see?" without reading code.

**Capsule shape.** A capsule is a struct, not a string. It has typed fields
(e.g. `pantry_items :: [%{name, last_seen_at, provenance}]`) and a
`to_prompt/1` function that produces the compact text the model receives. UI
and verifiers can read the struct directly without re-parsing prose.

**Compactness.** Each capsule has a token budget. If `RecipeAffinityCapsule`
returns 200 recipes, it summarises to the top 20 + a count. The summarisation
rule lives in the capsule, not in the run.

**Hard rules.**

- No run dispatches to `chat_with_tools/4` or any structured-output callback without an explicit capsule list.
- No code outside `lib/tore/harness/capsules/` may stuff data into a system prompt. `Tore.Chat.SystemPrompt.build/0` is deleted (done, 2026-06); its callers declare capsules on a run.
- A new feature that wants a new kind of context adds a capsule. It does not extend an existing capsule with "and also this."

### A.5 — Verifiers run after every state-changing run

A coding agent earns trust by running tests. Tore's harness earns trust the
same way: every state-changing `KitchenRun` is checked by a deterministic
verifier before anything it proposes is written. The LLM proposes. The
verifier decides if the proposal can actually land. The user sees a clean,
validated result — never a half-applied edit.

Verifiers are pure code, not LLM calls. They read the run's proposal and
the current state of what it would change, and
return either `:ok` or a structured `:fail` reason. They do not call models,
do not have side effects, and are cheap to run inline at the end of every
run.

**Verifier catalog (V1):**

| Verifier | Owns | Checks |
|---|---|---|
| `PlanVerifier` | `PlanDiff` | No locked/pinned slot was changed; every assigned recipe has servings; leftover slots point to a valid source meal earlier in the week; skipped slots are explicit, not missing; no banned ingredient or dietary constraint is violated; no recipe appears twice within the household's configured repeat window |
| `PantryVerifier` | `PantryBeliefUpdate` | Provenance is set on every item write; no negative quantities; `last_seen_at` is monotonic per item |
| `RecipeProposalVerifier` | `RecipeProposal` | Title, ingredients (≥1), and instructions are present; servings is positive; no near-duplicate of an existing catalog recipe (title + ingredient overlap heuristic); no ingredient name is empty |
| `CostEntryVerifier` | `CostEntry` | Store, date, total are present; line items sum within tolerance of total; date is not in the future |
| `Tore.Household.Memory.Ops` | `MemoryBatch` | Each operation fits the current entries (exactly one match for a patch or remove, no duplicate add); the part stays within its size limit; no content that is an instruction, a credential, hidden characters, an internal id or an allergy. A batch applies whole or not at all |

Kinds with no LLM step check less. `:plan_edit_run` refuses a change to a pinned day,
and `:shop_edit_run` accepts every change, since what it writes is what the person said.

**Verifier lifecycle.** After `propose` and `resolve`, `Runs` calls the kind's
`verify`, and one of three things happens:

- **Pass.** `apply_proposal` writes, and the run becomes `:applied` in the same transaction.
- **Fail.** Nothing is written. The run becomes `:failed` with a structured `failure_code` (e.g. `:slot_pinned`, `:near_duplicate`, `:dietary_violation`) and a `repair_action`. Screens turn the code into a sentence. The surface shows a compact repair state with a dismiss option. *Example: "Tuesday dinner is pinned, so nothing was changed."* (An ambiguous reference like "the salmon" matching two recipes is **not** a verifier failure — the resolver returns `:ambiguous` mid-loop and the LLM must `ask_user`, per §A.6.2. Verifiers catch proposals that cannot land; resolvers catch references that cannot be trusted.)
- **Review.** When the kind's `review_question/1` asks, the run waits in `:needs_user` with its proposal, and `verify` runs again on the edited proposal when the person confirms.

**No partial applies.** A verifier failure is atomic — nothing commits. This
is the load-bearing rule. The run is either fully applied or not applied;
the user is never asked to clean up a half-edited week.

**Concurrency and drift.** Runs hold no locks and never block a person's direct
edits. When `apply_proposal` finds, inside its transaction, that a check no longer
holds (a memory entry changed since `verify`), it returns `{:fail, code, repair}` and
the run fails with nothing written. Revert doesn't re-check: undo restores the
before-image, even over a later edit (§A.2).

**No model retry on verifier failure.** When verification fails, the harness
does not silently re-run the LLM with the verifier reason in the prompt.
That path is tempting (cheap retry, often fixes the failure) but it hides
bugs and produces non-deterministic spend. The repair state is surfaced to
the user; they decide whether to retry.

Memory is the exception. Its check is about wording the model can fix, not
about state the household owns, so the weekly review retries once with the
rejection inside `propose`, and Capture hands a rejected batch back to its
model (§1).

**Hard rules.**

- Every run kind implements `verify`. A kind whose proposal comes from the LLM checks it against a verifier in this table; a kind that only writes what the person said may check less (above).
- Verifiers run inside the harness, not inside the LLM tool layer. The LLM never sees verifier failure reasons during a run, except memory's (above).
- Verifier failures are stored on the `KitchenRun` row for later inspection; a verifier that fails 20% of the time across runs is a signal to fix the tool, the prompt, or the verifier — not to retry harder.

### A.6 — Risk tiers, resolved references, and Kitchen Skills

#### A.6.1 — Risk tiers

Every `KitchenRun` kind is classified into one of four tiers. The tier
determines whether the harness auto-applies, surfaces for inspection, or
requires explicit confirmation before anything is written.

| Tier | Examples | Apply policy |
|---|---|---|
| **Tier 0 — Surface only** | Capture's `suggest_from_fridge` and `suggest_meals_from_pantry` tools | They reply with what they found and write nothing, so they need no run. Acting on a suggestion is a separate request. |
| **Tier 1 — Reversible domain edits** | `:planner_command_run`, `:weekly_planning_run`, `:set_plan_slot_run`, `:plan_edit_run`, `:shop_edit_run`, `:pantry_belief_update_run`, `:memory_review_run`, `:memory_update_run` | Auto-apply after verifier passes. The run receipt is visible. Undo is one tap. |
| **Tier 2 — Reversible ingestion** | `:receipt_ingestion_run`, `:recipe_ingestion_run`, and a planner run that proposes a recipe | Reviewed when the kind's `review_question/1` asks, per the rule below. Otherwise applies straight away with undo. |
| **Tier 3 — Destructive or sensitive** | Bulk operations like *clear the week*; any change touching dietary constraints or allergens | Never auto-applies. Proposal is produced; commit requires explicit user confirmation. |

A kind decides whether to ask for review from its proposal alone, in
`review_question/1`:

- **Recipes** always wait for review, from a link, a photo or the planner.
- **Receipts** wait only when the line items don't add up to the total. The parser returns no line prices yet, so in practice every readable receipt applies straight away.

Shelf photos are Tier 1 and apply straight away, since one misread item is one tap to fix.

**Hard rules.**

- Review is decided by the kind's code from the proposal, never by the model. The model cannot escalate or de-escalate.
- Tier 3 is the only tier with a confirm modal. Tiers 0 and 1, and receipts, use act-then-undo; recipes wait for review. The UI never asks "are you sure?" for Tier 1 or 2.
- A run that touches household preferences (diet, allergies) is Tier 3 regardless of its declared kind.

#### A.6.2 — Resolved references, never raw IDs

The LLM never passes a raw aggregate ID to an action tool. State changes
happen through **resolver tools** that return typed handles with provenance,
and action tools that accept those handles.

A handle is a struct:

```elixir
%ResolvedRecipe{
  id: 123,
  label: "Salmon pasta",
  source: :search_recipes,        # which resolver produced it
  confidence: 0.91,
  ref: "rcp_a1B2c3"               # opaque token, registered per run
}
```

The same shape applies to `ResolvedSlot`, `ResolvedGroceryItem`,
`ResolvedPantryItem`, `ResolvedDeal`. Every handle carries `source`,
`confidence`, and a `ref` registered to the run that resolved it.

**Ref tokens and the per-run registry.** The LLM never sees the handle
struct itself, and never sees a raw aggregate ID. Every handle also carries
an opaque `ref` token (e.g. `rcp_a1B2c3`, `slt_x9Y8z7` — a short prefix plus
random base64url) minted when the handle is created. Read-tool results that
produce handles carry them under a reserved `__handles__` key; the
PlannerAgent runtime pops that key, registers each handle in a per-run
registry, and strips it before the result is JSON-encoded for the model —
so the model only ever sees `ref` and `label` strings, never an ID. When the
model calls an action tool with a `_ref` argument, the runtime looks the ref
up in the run's registry and, on a hit, substitutes the real ID into the
tool args before running the tool. On a miss (an invented or stale ref) the
tool is **not** invoked — the model gets a tool error telling it to call the
matching resolver or search tool first — though the call still counts
toward `max_action_calls`.

`source` values include `:search_recipes`, `:resolve_recipe`, and
`:direct_touch`. `:direct_touch` means the user physically touched the
object in the UI (e.g. opened a plan slot's sheet) — there is no resolution
step, so confidence is always `1.0`. Object sheets on the tonight card and
grocery rows mint direct-touch handles the same way the plan slot sheet
does.

**Resolver tools (V1):**

- `resolve_slot(reference :: String.t())` — natural-language slot reference (`"tonight"`, `"Tuesday lunch"`, `"the salmon slot"`) → `ResolvedSlot` or `:ambiguous` with candidates.
- `resolve_recipe(reference :: String.t())` — fuzzy recipe match by title or attribute → `ResolvedRecipe` or `:ambiguous`.
- `resolve_grocery_item(reference :: String.t())` — match by name + unit against the current list → `ResolvedGroceryItem`.
- `resolve_pantry_item(reference :: String.t())` — match against approximate inventory → `ResolvedPantryItem`.

**Action tools take handles, not IDs:**

```elixir
assign_recipe(slot_handle, recipe_handle, servings?)
swap_recipe(from_slot_handle, to_slot_handle)
```

If a resolver returns `:ambiguous`, the LLM is expected to call `ask_user`
rather than guess. The harness will not accept an action tool call with an
unresolved or invented handle: any ref not present in the current run's
registry is rejected.

**Hard rules.**

- Action tools may not accept raw IDs. The Tool struct's parameter schema rejects an `integer` where a handle is expected.
- The confidence threshold (default 0.7) is enforced in the resolver: below it, or without a clear gap to the runner-up, the resolver returns `:ambiguous` instead of a single match. Ambiguous candidates are still registered, so after `ask_user` the LLM can act with the ref the user picked.
- The same handle may be reused within a single run but not across runs. The registry is per-run, so a ref minted in one run does not exist in another; the harness looks the ref up in the current run's registry on every action call.

**Implementation status (V1).** Shipped: `resolve_recipe` (Jaro similarity
over the recipe catalog), direct-touch slot handles (minted by the
planner kinds when a run is scoped to a slot the user opened in the UI, e.g.
the plan slot sheet's scoped command input), and `resolve_slot` (2026-08 —
see below). Deferred until their consumers exist: `resolve_grocery_item`,
`resolve_pantry_item`, grocery-item handles. Slot-targeting action tools
(`assign_recipe`, `swap_recipe`, `skip_meal`, `mark_leftover`,
`set_servings`, `remove_recipe`) still take a structural `slot_key` domain
key rather than a `ResolvedSlot` ref — by design, not a gap: slot keys are
stable, deterministic, and never ambiguous, so there is nothing for a
resolver to disambiguate.

**`resolve_slot` (shipped, 2026-08) — structural, not a handle.** Unlike
`resolve_recipe`, `resolve_slot` does not mint a `ResolvedSlot` ref or go
through the `__handles__`/registry machinery. The slot domain is closed
(`{mon..sun}_dinner`) — the model cannot invent a usable key that the
action tools' existing structural validation wouldn't already reject, so
ref-token indirection buys nothing. `resolve_slot(reference, slots:, today:)`
is a pure, deterministic function (day words, "tonight"/"today"/"tomorrow"
relative to `today`, and Jaro similarity over assigned-recipe titles for
references like `"the salmon dinner"`) that returns
`{:ok, %{slot_key:, label:}}`, `{:ambiguous, candidates}`, or `:not_found`
directly — no LLM. Exposed to the planner as a read tool; on ambiguity the
model is instructed to `ask_user`, never guess.

#### A.6.3 — Kitchen Skills

**Status: planned, nothing built.** Each skill has to pass the upkeep test when it's picked up.

A Kitchen Skill is a reusable agent runbook: a pre-declared `KitchenRun`
kind with its capsules, tools, verifier, and target artifact set. Skills are
how the user invokes a higher-order operation without typing a free-text
command.

Each skill is a small typed declaration. The skill catalog is the V1 surface
of the harness for ordinary household operations.

**V1 skill catalog:**

| Skill | Dispatches | Purpose |
|---|---|---|
| `PlanMyWeek` | `:weekly_planning_run` | Generate the upcoming week from current pantry, deals, memory, and past affinity |
| `UseTheDeals` | `:weekly_planning_run` (deal-weighted) | Re-plan the week prioritising current active deals |
| `LowEnergyWeek` | `:weekly_planning_run` (low-effort weighted) | Plan a week of short-cook recipes with cascading leftovers |
| `StretchLeftovers` | `:planner_command_run` | Re-arrange the current week to maximise leftover cascades |
| `LearnFromThisWeek` | `:memory_review_run` | Force an out-of-schedule memory review from recent events |

The runbook fields (`trigger`, `capsules`, `tools`, `verifier`, `artifact`,
`surface`) live in a future Skills sub-spec. The umbrella names the concept
and the V1 list only.

**Surface rule.** Skills appear in the UI as small contextual action chips
on the surfaces where they are relevant (e.g. `PlanMyWeek` on Plan). There is no global "skills" management screen.

**Hard rule.** A skill is just a pre-declared `KitchenRun` kind with bound
parameters. It is not a separate primitive. Removing a skill is removing a
row from the catalog, not a refactor.

### A.7 — Inspectability

Every `RunArtifact` produced by a `KitchenRun` carries enough information
for the user to ask *why this?* and get a concrete answer. Inspectability is
not a separate logging or telemetry layer — it is a contract on the artifact
shape.

**Each artifact field that drove a user-visible decision must carry its
rationale inline.**

Examples:

- A `PlanDiff` slot change carries a `rationale` field: `"Pork on sale at ICA · matches a high-affinity recipe · Tuesday has no prep dependency"`.
- A `PantryBeliefUpdate` carries `provenance` per item: `grocery_checkoff`, `vision` (a shelf photo) or `manual`.

Rationale strings are produced by the run, not by the LLM at render time.
They reflect what actually drove the decision: the capsule fields the model
read, the deals it weighted, the memory it drew on. A rationale that says
only *"the model picked it"* is a harness bug.

**UI contract.** The surface always renders the artifact's summary form by
default. The rationale and evidence are revealed on a deliberate inspect
gesture. The harness guarantees the data is there; UI/UX spec decides the
affordance.

**Hard rules.**

- Every artifact field that surfaces a decision carries a rationale or provenance.
- Rationales are short and concrete — not paragraphs, not LLM prose. The verifier owning the artifact checks rationale presence as part of artifact validity.
- A run that produces an artifact with empty rationales fails its verifier. There is no "the model didn't explain" fallback.

**Known gap (2026-11-10).** The verifiers don't check rationale presence: `is_rationale_complete/1` has had no caller since run core.

### A.8 — Model routing

The harness routes LLM calls to one of three model tiers based on the
callback's pattern (§LLM Interface Conventions) and the run kind's risk tier
(§A.6.1). Routing is per-callback, not per-feature. The model used on each
call is recorded on `AIOperations.model` for cost telemetry.

**Model tiers (V1):**

| Tier | Use cases | Default model class |
|---|---|---|
| **Cheap structured** | Pattern A callbacks that parse or summarise: `parse_receipt`, `parse_pantry_image`, `cook_mode_steps`, capsule `to_prompt/1` token reductions | A fast small model with reliable strict-JSON support |
| **Strong tool-capable** | Pattern B `chat_with_tools/4` for `:planner_command_run`, `:weekly_planning_run`, Capture's router, and any future skill-driven run that calls multiple tools across multiple turns | A frontier tool-calling model |
| **Vision** | Any callback whose primary input is an image or PDF: `parse_receipt`, `parse_recipe_images`, `parse_pantry_image` | A vision-capable model; may overlap with "cheap structured" when the structured-output is small |

Concrete model names are configured per tier in runtime config, not
hard-coded in callsites. Today's runtime keys are `openrouter_model`,
`openrouter_vision_model`, `openrouter_image_model`, and
`openrouter_check_model` (+ `_fallback`). The routing sub-spec maps these
onto the three tiers: `openrouter_strong_model` and `openrouter_cheap_model`
land with it and subsume today's general/check split.

**Fallback rule.**

- **Pattern A schema-validation failure.** A structured-output callback whose response fails strict schema validation retries **once** with the strong-tier model. If that also fails, the call returns `{:error, :schema_unsatisfiable}` and the parent run records the failure. No third attempt.
- **Pattern B tool-loop failure.** A `chat_with_tools/4` run whose verifier fails does **not** auto-retry with a stronger model. The repair state surfaces to the user (§A.5).

**No per-feature routing.** A skill or run kind cannot override the model
tier its callbacks would normally use. This rules out the "this feature
deserves the strong model" creep that produces opaque cost lines on the
bill.

**Hard rules.**

- Every `Tore.LLM` callback is statically annotated with its model tier. The annotation is read at runtime by the adapter; there is no per-call model override.
- `AIOperations.model` is set on every row. A run's `prompt_tokens`, `completion_tokens` and `cost_usd` hold the usage its `propose` returned; calls that end in a question or an error are counted in `llm_usage` only.
- The schema-failure single-retry path is the only place the harness silently uses a different model than the callback declared. The retry is logged distinctly (`AIOperations.kind` ends with `.retry`). The household's monthly limit in `Tore.LLM` remains the runaway-cost guard.

### A.9 — Meeting point with docs/specs/ui.md

This spec owns the harness contract: run kinds, artifact shapes, capsule
declarations, verifier checks, risk tiers, resolver handles. `docs/specs/ui.md`
owns the surface contract: how artifacts render across Today / Plan / Shop /
Capture / Cooking / Settings, the visual system, the run-receipt and
thinking-state and failure-state and undo and "Why this?" patterns.

The two specs meet at artifact schemas. Concretely:

- A run's artifact (§A.3) drives Capture's one-line receipt (docs/specs/ui.md §7.1) and the run review page's card (§5.2).
- `KitchenRun.phase` (§A.2) drives docs/specs/ui.md §7.2's operational thinking-state strip.
- A failed run's `failure_code` and `repair_action` (§A.5) drive docs/specs/ui.md §7.3's failure-state card.
- Per-item `rationale` and `evidence` on every artifact (§A.7) drive docs/specs/ui.md §7.5's "Why this?" expansion.
- `RecipeProposal` fields drive the recipe proposal on the run review page.
- Household memory's parts and how full each is (§1) drive Settings' kitchen memory section.

When docs/specs/ui.md adds a surface that needs an artifact field this spec didn't
name, that's a SPEC.md amendment, not a UI-side workaround. When this spec
declares a field that no UI surface consumes, that's a SPEC.md trimming
opportunity. Both specs evolve together at the artifact-schema boundary; no
side silently degrades.

---

## Features

Status of everything Tore does, or is meant to do. Each built feature is described below as one or more
`KitchenRun` kinds with its capsules, tools, artifacts, verifier, risk tier and model tier.

| Feature | Status |
|---|---|
| §1 Household memory | Built (2026-11-10). Replaced insight synthesis |
| §2 Natural-language planner | Built |
| Weekly planning (`:weekly_planning_run`) | Built. Runs Saturdays at 18:00 and fills open slots |
| §3 Anticipation | Removed, apart from the long-press object sheets |
| §4 Pantry as belief, with shelf photos and shelf life | Built |
| §5 Receipts for cost | Built |
| §6 Fridge photo suggestions | Built, as a reply only |
| §7 Eating out | Built |
| §8 Stores and deals | Built, for ICA only. See its known problems |
| §9 Prep | Built, optional and on demand |
| Recipe import from a link or photo | Built, through `:recipe_ingestion_run`: Capture reads it, a person reviews it, then it's saved |
| Recipe proposals from the planner: find on the web, import, adapt (§2) | Built |

**Run kinds in the code** (`Tore.Harness.Kinds`): `:planner_command_run`, `:weekly_planning_run`,
`:set_plan_slot_run`, `:plan_edit_run`, `:shop_edit_run`, `:pantry_belief_update_run`, `:receipt_ingestion_run`,
`:recipe_ingestion_run`, `:memory_review_run` and `:memory_update_run`.

**Planned, in order.** Working specs live in `.docs/specs/`, which isn't versioned.

1. Pantry rules.
2. MCP, so someone can use Tore through their own Claude or ChatGPT. Its writes go through `Runs.submit/4`; the kinds' `open/1` will need to take the actor, since each sets `:user` or `:system` today.
3. Weekly budget: plan to a budget using deals, then a verdict and a learned estimate at week's end.
4. Instagram recipes.
5. A prep upgrade.

Several households on one server, with a gate on who may use the server's LLM, landed on 2026-11-09 (§Auth and Multi-Tenancy).
Run core and household memory landed on 2026-11-10 (§A.2, §1).

### 1. Household Memory → `:memory_review_run`, `:memory_update_run`

**Status: built (2026-11-10). Replaced insight synthesis.**

The household keeps a small memory that its members share, kept the way the Hermes agent keeps one:
a **profile** (who lives here, what they like) and **notes** (habits and patterns), each with a size
limit. A note about one person names them: *"Anna dislikes mushrooms."* `MemoryCapsule` puts both
parts, with how full each is, into the prompts of the planner and the weekly review. Capture's prompt
gets it too, and its `memory` tool returns the memory as it stands after each saved change.

Two kinds write it. Both check every batch with `Memory.Ops` (§A.5):

- **`:memory_review_run`**, weekly (Sat 06:00). It reads the memory snapshot, `RecentHistoryCapsule` and `RecipeAffinityCapsule`, and proposes add, patch and remove operations through the `memory_review` prompt (Pattern A, cheap structured). A rejected batch is retried once with the rejection; rejected twice, the run fails and nothing changes. Most weeks it changes nothing, and with no planning history it makes no LLM call.
- **`:memory_update_run`**, from Capture's `memory` tool. *"We've stopped eating fish on weekdays"* is saved without being asked for. The reply is a quiet "Noted:", "Updated:" or "Forgot:" line with Undo, or "Already noted." A rejected batch goes back to the model to fix, and the person sees nothing.

- **Artifact:** `MemoryBatch`.
- **Verifier:** `Memory.Ops`.
- **Tier:** 1, with undo (`restore_memory`).

Allergies and dietary rules stay in Preferences, where `PlanVerifier` enforces them. Memory refuses
them, and Capture points to the kitchen page, where Preferences live, so a refused allergy isn't
mistaken for a saved safety rule. Removing an entry in Settings is direct and needs no run.

What the review looks for: `MealSkipped` events grouped by weekday → *"skips Thursdays 7/10 weeks"*;
`RecipeRemoved` and `RecipeSwapped` → dislikes and friction; `LeftoverDay` patterns → which cascades
survive; slot fill rate by week → *"rarely plans past Wednesday"*. `MealSkipped` carries an optional
`reason`, so memory can tell "we went out" from "we skipped it".

**Hard rule:** There is no rating UI. Nothing asks *"how was dinner?"*. The signals are the event
stream and what people say in Capture.

### 2. Natural-Language Planner → `:planner_command_run`

**Status: built.**

The user types into the planner command bar. The harness starts a
`:planner_command_run`.

- **Capsules:** `HouseholdPreferencesCapsule`, `MemoryCapsule`, `WeekPlanCapsule`, `PantryBeliefsCapsule`.
- **Tools:** resolver tools (`resolve_slot`, `resolve_recipe`, `resolve_grocery_item`); action tools that take handles (`assign_recipe`, `swap_recipe`, `skip_meal`, `mark_leftover`, `set_servings`, `remove_recipe`); read tools (`search_recipes`, `pantry_snapshot`, `active_deals`, `find_recipe_web`); proposal tools that end the loop with a `RecipeProposal` (`import_recipe_from_web`, `generate_recipe_variant`); terminal `ask_user`.
- **Artifacts:** `PlanDiff`; a `RecipeProposal` instead when a proposal tool ends the loop.
- **Verifier:** `PlanVerifier`; `RecipeProposalVerifier` for a proposal, again when it is saved.
- **Tier:** 1 — auto-apply with undo. The run receipt is the user-facing confirmation. A proposal is Tier 2: the run waits in `:needs_user` until a person saves it, which writes the recipe and fills the pending slot, or discards it, which saves nothing. Web search has a SpendGuard estimate and cooldown (`:recipe_web_search`); every call counts against the household's monthly limit.
- **Model tier:** strong tool-capable (Pattern B).

**Loop caps** (enforced by the harness): 6 LLM round-trips per utterance, 12
action-tool calls per utterance (read tools don't count). Action tools run
sequentially in call order. An action-tool error is fed back to the LLM; the
model decides whether to retry, alter the plan, or call `ask_user`.

**Resolver-handle rule** (§A.6.2). Action tools take `ResolvedSlot` /
`ResolvedRecipe` handles, never raw IDs. A resolver returning `:ambiguous`
forces the LLM to call `ask_user` rather than guess.

Every loop iteration is logged to `AIOperations` with the run's
`correlation_id` and a per-call `step_index`. The required LLM callback
`chat_with_tools/4` is specified in §LLM Interface Conventions.

**Hard rules.**

- Buttons still work. NL is the power path; it is never the only path.
- The LLM cannot read or write anything outside the registered tool surface. No direct DB access from prompts, no template-expanded pantry dumps mid-loop.
- The agent never silently guesses an ambiguous reference. *"The salmon"* matching two recipes forces `ask_user`. The harness enforces this by rejecting unresolved handles.
- The agent never changes a day marked as eating out (§7). Only a person can. The tools enforce this, because `PlanVerifier` sees the plan only after a run's changes and so couldn't tell.

### 3. Anticipation

**Status: removed 2026-11-08, apart from the object sheets.**

Plan 3 built an `:ambient_scan_run` that predicted one action per surface each morning and after edits, stored
as `CounterNote`s and shown on Today, the plan slot sheet, the Shop add field and the Capture tray. The owner cut
it when the trim was rebased onto it, along with `CounterNote`s and `CounterNoteVerifier`.

What stays from Plan 3:

- **Object sheets.** A long press on the tonight card opens a sheet with a command input scoped to today's
  slot, which starts a `:planner_command_run` with `scoped_slot`, as the plan slot sheet does. A long press on a
  grocery row opens one for that item, which goes through `Capture.Router` with the item named in the text,
  because no grocery action tools take a handle yet.
- **`resolve_slot`**, the deterministic slot resolver (§A.6.2).

**Hard rule.** Anything anticipatory appears inline on the relevant surface. It is never delivered as push, email
or any other interruption.

### 4. Pantry as Inference → `:pantry_belief_update_run`

**Status: built.**

Three channels update the pantry through a `:pantry_belief_update_run`: a grocery item checked off, a shelf photo
through Capture, and a manual add or removal through Capture. Receipts are not a channel (§5).

- **Capsules:** `PantryBeliefsCapsule` (the current state, framed as belief).
- **Tools:** vision prompt `parse_pantry_image` for photos; none for a grocery check-off, which is deterministic.
- **Artifact:** `PantryBeliefUpdate` (items added or removed, each with `provenance`: `grocery_checkoff`, `vision` or `manual`). Undo puts each touched row's before-image back.
- **Verifier:** `PantryVerifier`.
- **Tier:** 1 — every channel applies straight away with undo. No review card.
- **Model tier:** vision (photo input only).

**Shelf photos.** A photo shows what's there, so its quantities replace the old ones instead of adding to them.

**One row per ingredient.** A unique index on `(household_id, ingredient_id)` holds it. Undoing a removal yields
to a row added since. Undoing a check-off unchecks the item and leaves the pantry as it is; if that's wrong, Capture
can remove the item.

**Shelf life.** The LLM guesses `shelf_life_days` per ingredient the first time it sees one, and the guess stays on
the ingredient. A pantry row's date follows `Tore.Pantry.Expiry`:

- A printed date read from a photo beats a guess.
- A date the household sets beats both until the item is bought again, and teaches that ingredient's shelf life.
- Seeing an item again never makes it fresher, so a photo never extends a date. Buying it starts over.

The date affects three things:

- **Belief:** a row past its date becomes `:uncertain`.
- **Planning:** past-date rows don't count as available, and `PantryBeliefsCapsule` lists what to use soon first.
- **The list:** past-date items stop showing as probably at home, so they're bought again.

**Demotion:**

- The `/pantry` route is removed from main nav.
- `pantry_live.ex` is a *"Here's what we think you have"* view reachable from Settings. Two actions: remove an item, and set its date. No add.
- `PantryBeliefsCapsule` frames inventory as approximate. Items carry `last_seen_at` and `provenance`.

**Hard rule.** Spec or implementation work that adds back a primary
pantry-management screen is a regression of this requirement.

### 5. Receipts → `:receipt_ingestion_run`

**Status: built.**

A receipt photo, from Capture or the cost page, dispatches a `:receipt_ingestion_run`. Receipts record what was
spent and nothing else. They never touch the pantry or the shopping list, because a misread line would drop an item
off the list.

- **Capsules:** none — the input is the image; no household state required for parsing.
- **Tools:** vision prompt `parse_receipt`.
- **Artifact:** `CostEntry` (store, date, total, line items, optional photo path).
- **Verifier:** `CostEntryVerifier`.
- **Tier:** 2 — reviewed only when the line items don't add up to the total (§A.6.1), so today every readable receipt applies straight away. Undo deletes it.
- **Model tier:** vision.

The same photo sent twice is caught and says it's already uploaded. Line items carry names, not prices. Capture can
also delete a receipt outright: the model lists recent receipts (`list_receipts`) and deletes the one named
(`delete_receipt`).

### 6. Fridge Photo → Suggestions

**Status: built, as a reply only. It isn't a run.**

The `suggest_from_fridge` Capture tool reads the photo with `parse_pantry_image` and replies with what it can see,
offering to suggest recipes. It writes nothing. If the person says yes, the `suggest_meals_from_pantry` tool replies
with recipes that fit the pantry. Putting one on the plan is a separate `set_plan_slot` request.

### 7. Eating Out

**Status: built.**

Eating out is a state of a day in the plan, not a cost form. "Eating out" on the day's sheet, or saying so to Capture
(the `mark_eating_out` tool, through `:plan_edit_run`), emits `MealSkipped` with `reason: "eating_out"`.

- It cancels any recipe that day, and it works on an empty day too.
- Place and amount are optional, and can be added later from the sheet or Capture. They ride on the `MealSkipped` event and live on the day in the plan state; there is no separate table.
- "Not eating out", or picking a recipe for the day, clears them with the day.
- Undoing an earlier change to that day puts it back as it was, eating out or not. Capture can mark it again.
- It isn't a gap in the plan: `PlanHealth` doesn't count it, weekly planning leaves it alone, and the planner can't overwrite it (§2).
- Today says so instead of showing a dinner. The cost page reads the amounts from the plans.

### 8. Stores and Deals

**Status: built, for ICA only.**

A store is added in Settings by pasting a link to its offers. `Tore.Deals.Parsers.for_url/1` picks a parser from the
link's host, and each chain is one module implementing `Tore.Deals.Parsers.Parser`. Only https links on a parser's
hosts get fetched, so a pasted link can't point Tore anywhere else. A link no parser handles gets "Tore can't read
that store yet". A Saturday job scrapes every enabled store, and the planner reads the results through `active_deals`.

**Known problems.** Tested on 2026-11-04 against one ICA store: `Req`, which the scrape uses, gets a 403 where plain
`curl` gets a 200, and the parser truncates decimals and misreads multi-buys. These get fixed with the weekly budget,
and until then the Saturday scrape may return nothing. When fetching is fixed, the limits are one store, at most once a
day and only until the new week's offers appear, with no retries on a 403.

### 9. Prep

**Status: built, optional and on demand.**

Plan links to "Prep this week". The page generates a guide from the week's plan when asked, through
`Tore.Prep.generate_guide/3` and the `prep_guide` prompt. It's a document to read: there's no scheduled job and no
"report back". It isn't a run, since it changes nothing else.

---

## Interfaces

### Home (`/`)

The phone/laptop landing surface, distinct from the planner.

- Tonight + tomorrow card pair. A night marked as eating out says so instead of showing a dinner.
- A review pill when runs are waiting for the household. It opens the oldest one, then returns to Home.
- A week strip showing this week's plan at a glance.
- Capture pill → `/capture`.

### Planner (`/plan`)

- Week view with editable slots.
- A command bar at the bottom: text input + voice (phase ≥ 8) that runs through `PlannerAgent` (§2).
- Slot interactions still work via tap (assign, swap, skip, mark leftover, set servings, eating out).
- A "Prep this week" link (§9).

### Capture (`/capture`)

Full-screen capture surface that accepts text and photos. One LLM tool loop handles each input: the model sees the
text and all photos together and calls the tools that fit (`Tore.Capture.Router`). A photo can become a receipt, a
recipe, a shelf update or a fridge reply. Each capture leads to a typed result the surface renders, not a
conversation thread.

Each write a turn makes is its own run and shows as its own line, with Undo where the
run has one. Typed edits go through `Runs.submit/4`; photos, links and pantry edits
through `Runs.start/3`. The runs: plan edits (`:plan_edit_run`, `:set_plan_slot_run`), the
shopping list (`:shop_edit_run`), the pantry, receipts, recipes (`:recipe_ingestion_run`,
whose line links to its review) and memory (`:memory_update_run`). Building the
shopping list has no Undo, since it replaces the list.

Deleting a recipe, a receipt or a shopping item is a plain tool with no review or undo.
The model finds the id itself (`find_recipe`, `list_receipts`) and deletes only what the
person clearly named, asking when more than one matches.

### Shop (`/shop`)

The reliability anchor. Manual add always works. Plan changes broadcast to
update the list automatically, but the list survives a missing plan, a
missing pantry, and a missing connection to the LLM. Checking an item
dispatches a `:pantry_belief_update_run` (see §4).

### Settings (`/settings`)

- Members, by name and Pocket ID username. Add someone by their Pocket ID username; remove a member, or leave. The last member can't leave, since the household's data would have nobody to reach it. "Sign out".
- Household: rename it; the language, picked at `/welcome` when the household was created and shown locked.
- **Your households:** a switcher, shown only to someone in two or more.
- AI: someone with the `tore_ai` claim can let the household use their credits ("Use my credits for this household"). Others see who sponsors it, or that AI is off.
- **Things Tore has learned:** the household memory (§1), as "Your household" (the profile) and "Notes", each with how full it is and a "Forget" button per entry. Either member can forget anything.
- **Stores:** add by link, switch on or off, remove (§8).
- AI usage.
- Links to the pantry view ("Approximate inventory") and costs ("Spending").

### Costs (`/settings/costs`, out of main nav)

One page, reachable from Settings:

- This month's total against last month.
- The five most recent receipts.
- Eating out this month, from the plans.
- Adding a receipt, by photo or by typing a total.

---

## Removed in Rewrite

The following exists in the codebase today and is **deleted** by this spec. Implementation
plans must remove these explicitly — they are not deprecated, they are gone.

| Removed | Replacement |
|---------|-------------|
| `pantry_live.ex` full CRUD (add/edit/category management UI) | Inferred pantry view in Settings; grocery check-offs, shelf photos and Capture add to it |
| `/pantry` in main nav | Removed entirely |
| `/costs` in main nav | Moved under Settings |
| `Tore.Family` context (introduced as the canonical name in the prior rewrite) | `Tore.Household` is canonical; `Tore.Family.*` deleted |
| Onboarding questionnaire (if/when added) | Inference from events over time |
| Any meal-rating or "how was dinner?" UI | Never built; explicitly prohibited |
| Any "you haven't logged in N days" reminder | Never built; explicitly prohibited |

---

## Module Map

Files marked `PLANNED` are named by this spec but not yet in the tree;
everything else reflects the code as of 2026-11-10.

```
lib/tore/
  scope.ex                   # %Scope{household_id, user_id}, the first argument of household functions
  streams.ex                 # event stream ids per household and week
  household.ex               # canonical household context (preferences, language, sponsor, each_scope)
  household/
    memory.ex                # profile and notes: snapshot, stores, write, forget, restore
    memory/ops.ex            # the pure batch check: plan/3 and the content rules
  members.ex                 # add, remove and switch members; pending members
  accounts.ex                # users; sign_in/1 from Pocket ID claims; the session's scope
  accounts/                  # user, membership, pending_member
  auth/
    oidc.ex                  # Pocket ID: authorization code flow with PKCE, over oidcc
  recipes.ex                 # catalog; owns scrape_and_create/generate_image (folded)
  recipes/                   # schemas, parser, variant.ex (an adapted recipe as a proposal)
  deals.ex                   # owns add_store/scrape_all/scrape_url
  deals/
    deal.ex
    store_config.ex
    parsers.ex               # picks a parser from the link's host
    parsers/                 # parser.ex (behaviour), ica.ex
  pantry.ex                  # inference-shaped: list, upsert_belief, remove_item, set_expiry, belief decay
  pantry/
    pantry_item.ex           # effective_belief
    expiry.ex                # a row's date from what was just observed. Pure
  costs.ex                   # receipts, eating out read from the plans, monthly totals, LLM usage
  costs/
  prep.ex                    # owns generate_guide (folded)
  prep/
  planning.ex                # imperative shell over the pure Planning aggregate
  planning/                  # Decider aggregate
    commands.ex              # AssignRecipe, SwapRecipe, SkipMeal, EatOut, ...
    events.ex                # MealSkipped, RecipeRemoved, RecipeSwapped, ...
    decider.ex
    state.ex
  plan_health.ex             # ready | flexible | fragile | unplanned
  week_mode.ex
  shop.ex                    # imperative shell over the pure Shop aggregate
  shop/                      # Decider aggregate
  ai_operations.ex           # low-level LLM call audit log; owned by KitchenRun
  capture/                   # Capture surface plumbing: router, uploads, dispatch
  harness/                   # the Agent Harness Layer
    kitchen_run.ex           # the runs row; kitchen_run/transition.ex (pure), kitchen_run/types.ex
    kind.ex                  # the Kind behaviour: propose, resolve, verify, review_question, apply_proposal, after_commit
    kinds.ex                 # kind name → module
    kinds/                   # planner_command, weekly_planning (sharing planner.ex), set_plan_slot,
                             # plan_edit, shop_edit, pantry_update, receipt, recipe_ingestion,
                             # memory_review, memory_update
    runs.ex                  # start, submit, confirm, discard, revert, queries, fail_interrupted
    undo.ex                  # {:steps, [step]} | {:irreversible, reason}
    inbox_sweeper.ex         # weekly TTL sweep: stale :needs_user → :discarded
    receipt_ingestion.ex     # parse, build and save helpers for Kinds.Receipt
    plan_diff_builder.ex
    artifact.ex              # RunArtifact behaviour + artifact/registry.ex
    artifact/                # plan_diff, recipe_proposal, pantry_belief_update, cost_entry,
                             # memory_batch, shop_change
    capsule.ex               # capsule behaviour; capsules.ex assembles per-run capsule lists
    capsules/                # 6 landed, memory_capsule among them; deals_digest_capsule + cost_intent_capsule PLANNED
    verifier/                # plan, pantry, cost_entry, recipe_proposal
    resolvers.ex             # resolve_recipe, resolve_slot; grocery item and pantry item PLANNED
    handles.ex
    skills.ex                # PLANNED: V1 Kitchen Skills catalog
  llm.ex                     # the gate and facade, scope first: text/4, web_search/4, vision/5, chat/4, chat_with_tools/5
  llm/
    spec.ex                  # wire-spec behaviour: provider body shape behind the facade
    openai.ex                # OpenAI-compatible Spec implementation
    prompts.ex               # JSON schemas + prompt templates (Pattern A operations)
    planner_agent.ex         # tool-calling loop runtime; emits into a KitchenRun
    planner_tools.ex         # tool definitions
    tool.ex                  # declarative tool struct
  image_gen/
    open_router.ex           # recipe images through the open_router library
  spend_guard.ex
  scheduler.ex
  storage.ex
```

```
lib/tore_web/live/
  home_live.ex
  planner_live.ex            # command bar drives PlannerAgent
  capture_live.ex            # capture → run dispatch → artifact rendering
  run_review_live.ex         # :needs_user review + receipt detail
  cooking_live.ex
  shop_live.ex               # check → :pantry_belief_update_run
  recipe_live.ex
  prep_live.ex
  settings_live.ex           # members, households switcher, rename, sign-out, stores, kitchen memory, AI sponsorship and usage
  welcome_live.ex            # /welcome: a new household picks its language once
  pantry_live.ex             # /settings/pantry: approximate inventory
  cost_live.ex               # /settings/costs: one page
```

```
lib/tore_web/controllers/
  session_controller.ex      # /login page, DELETE /logout
  oidc_controller.ex         # /auth/oidc and its callback
  dev_session_controller.ex  # /dev/login, dev only
lib/tore_web/user_session.ex # starts and ends a session
```

---

## LLM Surface

Every LLM call goes through the `Tore.LLM` facade and is logged to `AIOperations`
with a correlation ID. The facade exposes five transport callbacks, defined by
the `Tore.LLM.Spec` behaviour (a Spec encodes one provider's body shape and
decodes its responses; transport is the `open_router` library). The arities below are the
Spec's; each facade function takes the household's `%Scope{}` before them:

| Callback | Purpose |
|----------|---------|
| `text/3` | System + user prompt → strict-JSON structured output (Pattern A, text input) |
| `web_search/3` | `text/3` with OpenRouter's web-search plugin. Powers `find_recipe_web` |
| `vision/4` | Image/PDF blobs + prompts → strict-JSON structured output (Pattern A, vision input) |
| `chat/3` | Multi-turn messages → prose reply. Nothing calls it at the moment |
| `chat_with_tools/4` | Tool-calling chat. Powers `PlannerAgent` (§2) and every Pattern B run. |

Purpose-level operations are **not** behaviour callbacks. Each one — parse a
receipt, parse a recipe, parse a shelf photo, review the household's memory, suggest a
recipe, write a prep guide, compress cook-mode steps — is a prompt + JSON-schema pair in `Tore.LLM.Prompts`,
invoked through `text/3` or `vision/4`. Adding an operation adds a prompt
spec, not a callback. (The earlier draft's `generate_plan/1` callback is
gone: weekly planning is a Pattern B tool-calling run, §A.8.)

**The gate.** Every facade function takes the household's `%Scope{}` first. `Tore.LLM`
refuses a call with `{:error, :ai_unavailable}` when no OpenRouter key is configured or
nobody sponsors the household (a member with `ai_enabled` who turned sponsorship on, or who
started the household with the claim), and
with `{:error, :budget_exceeded}` once the household has spent `Tore.LLM.monthly_limit_usd/0`
this calendar month. It records every call's cost in `llm_usage` for the household, under
the call's `:feature`; each iteration of a `chat_with_tools` loop is its own call.
`Tore.LLM.check/1` gives the same answer without calling (the crons use it), and
`Tore.LLM.refusal_text/1` is what a screen says for either refusal, instead of "try again".
`Tore.SpendGuard` is the earlier check for expensive features: whether the estimate would
cross the limit, and a per-feature cooldown, both per household. Image generation
(`Tore.ImageGen`) runs only after the gated image-prompt call, and its cost isn't recorded yet.

---

## LLM Interface Conventions

Two patterns, used deliberately:

### Pattern A — Structured Output (default for parsers and extractors)

Used by every operation whose job is *"turn this input into a fixed-shape result"*:
`parse_receipt`, `parse_recipe_images`, `parse_pantry_image`,
`memory_review`, `suggest_slot_recipe`, `prep_guide`, `cook_mode_steps`. All go through `text/3` or `vision/4`.

- Implementation: OpenAI-compatible `response_format: %{type: "json_schema", json_schema: %{name:, strict: true, schema:}}`.
- Schemas live in `Tore.LLM.Prompts` next to the prompt EEx files.
- `strict: true` is mandatory — the adapter must reject any non-conforming output rather than best-effort parsing.
- One LLM round-trip per call. No loops. No tool registration.

### Pattern B — Tool-Calling Agent (for in-app actions)

Used when the LLM needs to *do something* in the app — read state, then write state,
possibly across several turns. Two consumers: `PlannerAgent` (§2) and Capture's
router (`Tore.Capture.Router`).

- Implementation: `chat_with_tools(system, messages, tools, opts)`. The adapter passes `tools` straight through to the model's tool-calling API.
- Tools are defined declaratively as `%{name, description, parameters_schema, kind: :action | :read, run: (args -> result)}`. The agent runtime, not the adapter, executes them.
- Tool schemas use JSON Schema and are validated before the tool's `run` function is invoked. Invalid tool calls are reported back to the LLM as a tool error message; the loop continues.
- The agent runtime enforces: max round-trips, max action calls, sequential execution for actions, parallel allowed for reads.
- Every round-trip is one `AIOperations` row, sharing a `correlation_id` with `step_index` for the sequence.
- The model comes from the strong tool-capable tier (§A.8). No per-call or per-feature override.

### When to use which

- **Parser, extractor, classifier, or "summarise this":** Pattern A. Always.
- **The LLM needs to look something up that wasn't pre-stuffed into the prompt:** Pattern B.
- **The LLM needs to perform actions that change app state and might require multiple steps:** Pattern B.
- **Anything new that doesn't clearly fit:** Pattern A first. Escalate to Pattern B only when a concrete use case shows single-shot can't reach the goal.

### Universal rules

- Every call logs to `AIOperations` with `model`, `prompt_tokens`, `completion_tokens`, `correlation_id`, and `step_index` (always 0 for Pattern A).
- Every call goes through the `Tore.LLM` gate for its household, except image generation, which runs only after a gated call and isn't recorded yet (§LLM Surface).
- No LLM-emitted SQL, no LLM-emitted code execution, no LLM-emitted shell. Tool surface is the only side-effect channel.
- System prompts are assembled from the run's declared context capsules (§A.4). There is no shared prompt builder; a call without a declared capsule list gets no household context at all.

---

## Quantum Schedule

```elixir
config :tore, Tore.Scheduler,
  jobs: [
    {"0 3 * * *",  {Tore.Deals,                          :clear_expired,      []}},
    {"0 4 * * 0",  {Tore.Harness.InboxSweeper,           :sweep_weekly,       []}},
    {"0 6 * * 6",  {Tore.Harness.Kinds.MemoryReview,     :review_weekly,      []}},  # starts :memory_review_run
    {"0 8 * * 6",  {Tore.Deals,                          :scrape_all,         []}},
    {"0 18 * * 6", {Tore.Planning,                       :plan_upcoming_weeks, []}}   # dispatches :weekly_planning_run
  ]
```

**Scheduled jobs go through the harness.** A cron job that writes state on the
AI's behalf starts a `KitchenRun` (with `actor: :system`) — it never
calls a context function directly, per §A.2's hard rule. `Tore.Deals.clear_expired`
and `scrape_all` are deterministic maintenance, not AI actions, and stay direct.

---

## Auth and Multi-Tenancy

A *household* owns all data: plans, groceries, pantry, costs, memory, recipes, runs, LLM usage.
*Users* belong to one or more households through `memberships`, exactly one of them active. Pocket ID is the only login: `Tore.Auth.Oidc` runs the authorization code
flow with PKCE, and `OidcController` hands the ID token's claims to `Accounts.sign_in/1`. A returning user
gets name, username and LLM access refreshed. A new one joins every household that added their username
(`pending_members`), active in the first and in its language, or else gets a household of their own, named
after them, whose language they pick once at `/welcome`.
A missing username, or one held by another Pocket ID account, is refused. Sessions are browser cookies
that last 90 days. "Sign out" in Settings ends the session in that browser and closes the app in its other
open tabs; other devices stay signed in.

Pocket ID decides access, not Tore. Its client for Tore allows only the `tore` group, so nobody else
reaches the callback. Members of `tore-ai` carry the claim `tore_ai = true` (the name is set by
`AI_CLAIM`), which sets `ai_enabled`. Tore decides only who shares a household: `Tore.Members` adds,
removes and switches. Adding someone never makes them the household's sponsor, so nobody reaches another
person's credits by adding them. `Tore.Household` is the canonical context. There is no `Tore.Family` module.

**Several households, one server.** The rules, from `.docs/specs/households.md`:

- Every function that reads or writes a household's data takes `%Tore.Scope{household_id, user_id}` first. LiveViews get it from `on_mount`,
  built on each request from the active membership, so a removal takes effect at once. Background jobs loop
  over households with `Tore.Household.each_scope/1`.
- `Tore.Repo.prepare_query/3` raises when a query on a household table has no `household_id:` option, and
  filters by it when it has one. A missed site crashes instead of leaking.
- Event streams (`plan:<household>:<monday>`, from `Tore.Streams`), PubSub topics
  (`plan:household:<id>`) and storage keys (`households/<id>/…`) carry the household id, and the image controllers load through the scope, so another household's id is a 404.
- Stores and deals are shared: a store is fetched once however many households use it (`household_stores`).
  Nothing else crosses households.
- The planning and memory review crons run only for households that can use the LLM (§LLM Surface).

---

## Backlog

Loose ideas captured here so they don't drift in a scratch file. Promote to a
proper section or sub-spec when picked up.

- **Locale on scraped recipes.** Scraped recipes should be translated into the household's locale at ingestion time.
- **Elixir 1.20 upgrade.** Move to the new type system and take advantage of it across `lib/tore/`.
- **HTML in `.html.heex` files.** Move inline templates out of `*_live.ex` modules into colocated `.html.heex` files.
- **Scraped recipe format** Even scraped recipes without llm should be sent to llm for translation if needed, and reformatted to the "tore format"

---

## Out of Scope for This Spec

- iOS/Android native apps. Mobile web is the target.
- Multi-family aggregation, social/sharing features.
- Nutrition tracking, calorie counting.
- Voice input (target for a later phase; the command bar is text-only initially).
- Anything that requires push notifications.

---

## Success Criteria

The rewrite is done when:

1. Every feature marked Built in §Features passes an end-to-end test on a real device.
2. `pantry_live.ex` no longer offers add/edit; the route is gone from main nav.
3. `cost_live.ex` is reachable only through Settings.
4. `Tore.Family.*` is deleted; `Tore.Household` is canonical.
5. `PlannerAgent` runs a bounded tool-calling loop driven from the planner command bar, with all action tools wired through `Tore.Planning` and at least two read tools (`search_recipes`, `pantry_snapshot`) wired to real context state.
6. Receipts uploaded via Capture or the cost page write to `costs` and never to `pantry`.
7. A fridge photo names what Tore sees and offers suggestions.
8. A user can skip a meal with one tap and the app says nothing back.
9. No notifications. No nags. No streaks.
10. Every state-changing AI action is a `KitchenRun` — visible as a row in the kitchen runs table, owning its `AIOperations` rows, carrying its declared capsules, producing its typed artifacts, gated by its verifier, classified into a risk tier. No code path writes household state on the AI's behalf outside a run, apart from the exceptions §A.2 names.
11. Every applied run carries the artifacts of what it changed, and every run waiting for review carries its proposal, with rationale-or-provenance fields populated where they surface a decision (§A.7).
