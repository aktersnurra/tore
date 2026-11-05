# Tore — AI-Native Meal Planner & Kitchen Kiosk

> *Tore* is a self-hosted family meal planner. The previous incarnation was *Scullion*,
> a competent but conventional CRUD-shaped planner. This document specifies the
> AI-native rewrite. Where this spec disagrees with the codebase, one of them is
> a bug: reconcile deliberately and record the decision in §Status. Neither side
> silently wins.

## Status

- **Source-of-truth date:** 2026-05-30
- **2026-05-31:** Reversed the Family→Household naming. `Tore.Household` is canonical; `Tore.Family.*` deleted.
- **2026-06-02:** Added §Agent Harness Layer. Tore is reframed as a household food-operations harness; every state-changing AI action is a `KitchenRun` producing typed artifacts, verified deterministically, applied atomically. §The Six LLM-Native Features rewritten in harness terms. Future sub-specs implement the harness primitives, verifiers, capsules, risk tiers, resolved references, and Kitchen Skills.
- **2026-06-02:** UI/UX vocabulary adopted. Canonical names: `CounterNote` (artifact and code module — replaces the working name `Opportunity` from the first draft of §A), `Shop` (UI surface and route `/shop` — replaces `Groceries` / `/groceries`), `Capture` (UI surface and route `/capture` — replaces `Chat` / `/chat`), `Tore.Capture` (module namespace — replaces `Tore.Chat`). The code rename is a separate sub-plan; SPEC.md uses the new names throughout from this commit forward.
- **2026-07-03:** Reconciliation pass. Absorbed what the run-receipts slice (`docs/specs/run-receipts.md`) and a month of implementation legitimately decided: the run aggregate is event-sourced (`Tore.Harness.Run`), a seventh `:discarded` terminal state with a weekly TTL sweep, `undo_payload` as a sum type replacing `undo_ref`, the `PantrySnapshot` / `RunBundle` artifacts, and the `:capture_turn_run` parent-run kind. Fixed internal contradictions (SystemPrompt, fridge-rescue tier, weekly planning Pattern A vs B, leftover Chat naming, Quantum jobs bypassing the harness). Made the single-household deployment assumption explicit. Decided: Capture keeps LLM photo classification (`classify_image`) rather than explicit intent chips — considered and rejected the chips.
- **2026-07-12:** §A.6.2 resolved-handles landed for plan slots. Decided: handles carry an opaque `ref` token (not the struct) to the model; the PlannerAgent runtime exchanges refs for real IDs at the action-tool boundary via a per-run registry, and rejects invented/stale refs as a tool error without invoking the tool. Added `:direct_touch` as a `source` value (confidence 1.0 — the user touched the object in the UI, nothing to resolve). Shipped: `resolve_recipe`, direct-touch slot handles from the plan slot sheet's scoped command input. Deferred: `resolve_slot`, `resolve_grocery_item`, `resolve_pantry_item` — until their consumers exist. Slot action-tool params stay structural `slot_key` domain keys by design, not a `ResolvedSlot` ref.
- **2026-08-04:** Anticipation layer landed (plan 3 of 3). `CounterNote` gained a `proposed_run` map column (sum type: `planner_command` | `add_item` | `nil`) and four scan kinds (`swap_suggestion`, `freezer_fallback`, `missing_ingredient`, `usual_item_missing`); `CounterNoteVerifier` checks every scan proposal before it is materialized. A new `:ambient_scan_run` (Tier 0, `started_by: "system"`) predicts at most one actionable note per surface daily at 05:00 and after a 5-minute-debounced plan/shop mutation, gated by SpendGuard `:ambient_scan {8_000, 600}`; `CounterNotes.recently_ignored/1` feeds dismissed notes back into the next scan prompt so the model does not re-propose them. `CounterNotes.follow_up/2` is the single accept-with-effect path: `add_item` applies directly (no LLM), `planner_command` dispatches `:planner_command_run` with `started_by: "counter_note_followup"` and Plan 2's `scoped_slot` machinery. Home hero, the Plan slot sheet, the Shop add-field, and the Capture tray's half state all render these notes as one-tap predictions per Rule 1 (replace generic affordances, never add elements) — never awaited on page load (Rule 2). §A.6.2: `resolve_slot` shipped as a pure, deterministic resolver — see below. Also shipped: long-press object sheets on the tonight card (scoped to today) and grocery rows (scoped via a `Capture.Router` text referent, since no grocery action tools exist yet to consume a handle).
- **Supersedes:** the original Scullion SPEC.md (2026-05-02), now archived in git history at commit `af0ad48`.
- **Companion docs:** `docs/LLM-NATIVE-FEATURES.md` (the design brief this spec absorbs), `docs/UI_SPEC.md` (UI/UX contract — meets this spec at the artifact boundary), `docs/specs/run-receipts.md` (the first vertical slice of the harness: receipts, diffs, undo). Per-feature design notes live under `docs/specs/`.
- **Naming:** the project is *Tore*. Any remaining reference to Scullion or Family in code is legacy and slated for deletion (see §Removed in Rewrite).

---

## Core Philosophy

Two sentences govern every decision in this spec:

1. **The system has a good guess and makes it easy to say yes or make a small correction.** The LLM does the work. The user approves, ignores, or nudges.
2. **The system should be more wrong about your kitchen and more right about your life.** Pantry counts will drift. Receipt scans will be skipped. But the system can learn that you skip Thursdays, that fish on weekdays doesn't stick, and that ICA has pork on sale — and that's the value.

Derived rules:

- **Skipping is first-class and neutral.** One tap. No "why?", no cascade warning. The plan is a proposal, not a contract.
- **No nagging.** No notifications about logging, no streaks, no reminders. The app is ready when you come to it.
- **The grocery list is the reliability anchor.** It works even if everything else is chaos. Manual add always works.
- **The kiosk has one job.** Tonight's meal + what's already prepped. Glanceable in two seconds with floury hands.
- **Trust the user's choices.** When the user overrides a suggestion, the app does not ask why. It notes the event and moves on.
- **Surface, never push.** Proactive intelligence appears in the UI when you open the app. It never sends a notification.

---

## Two Interfaces, One Backend

```
┌──────────────────────┐         ┌──────────────────────────────────┐
│  Raspberry Pi 5      │         │  VPS                              │
│  Nerves kiosk        │         │                                  │
│  Chromium ──────────────HTTPS──▶  Phoenix + LiveView              │
│  Device-token auth   │         │  Ecto + SQLite                    │
└──────────────────────┘         │  OpenRouter (LLM + vision)        │
                                 │  Garage (S3) for images           │
┌──────────────────────┐         │  Quantum scheduler                │
│  Phone / laptop      │         │  EventStore (planning, groceries) │
│  Browser ──────────────HTTPS──▶                                   │
│  16-digit code auth  │         └──────────────────────────────────┘
└──────────────────────┘
```

The Pi is a thin client. All logic runs on the server. The kiosk gets a deliberately
restricted UI (see §Kiosk). The phone/laptop gets the full planner.

---

## Pattern Strategy

Three aggregates are event-sourced via the Decider pattern. Everything else is Ecto CRUD
behind a context boundary. LiveViews call context APIs only; the context modules orchestrate IO.

### Event-sourced

| Aggregate     | Why                                                                |
|---------------|--------------------------------------------------------------------|
| **Planning**  | LLM-orchestrated workflow with frequent user tweaks. Events are the substrate from which insights are synthesised. |
| **Shop** | Multi-user real-time grocery checklist (decider stream `shop`, formerly `groceries`). Granular events enable PubSub sync and natural undo. |
| **KitchenRun** (`Tore.Harness.Run`) | Each run is its own event stream. A run *is* an audit trail — opened, phase transitions, commit/fail/revert/discard as events. Run receipts and the inbox are projections over these streams. |

### CRUD

| Context       | Role                                                              |
|---------------|-------------------------------------------------------------------|
| **Accounts**  | Users, sessions, per-user prefs.                                  |
| **Household** | Shared household-level state (preferences, insights, members). |
| **Recipes**   | Reference catalog.                                                |
| **Deals**     | Scraped weekly, expire automatically.                             |
| **Pantry**    | Approximate inventory. **No primary management UI.** See §Pantry. |
| **Costs**     | Receipts logged for cost tracking. **Not in main nav.**           |
| **Prep**      | LLM-generated text guides. Read-only.                             |
| **CounterNotes** | Ambient suggestions surfaced inline on Home/Plan/Kiosk as `CounterNote` artifacts. See §3. |
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
model routing. Every feature in §The Six LLM-Native Features below is then
re-described as a kind of run.

### A.2 — The unit is a `KitchenRun`

Every non-trivial AI action in Tore is a `KitchenRun`. A run is the food
equivalent of an agentic coding session: a bounded operation with a typed
beginning, a verified middle, and a reversible end. `AIOperations` continues
to record the low-level LLM-call audit log; a single `KitchenRun` owns one or
more `AIOperations` rows tied by `correlation_id`.

`KitchenRun` is the spec-level concept name; the code module is
`Tore.Harness.Run`, an event-sourced Decider aggregate (one stream per run).
The fields below are the state the aggregate folds up from its events, not
columns on a table.

**Fields:**

- `id` (stream id)
- `household_id`
- `kind` — one of the declared run kinds (see §The Six LLM-Native Features)
- `status` — `:draft | :running | :needs_user | :applied | :failed | :reverted | :discarded`
- `phase` — when `status: :running`, one of `:gathering_context | :proposing | :verifying`; `nil` otherwise. Drives the UI's operational thinking-state strip (UI_SPEC §7.2) — *"Checking the week…", "Looking at deals…", "Verifying changes…"*
- `started_by` — `:user | :scheduler | :counter_note_followup`
- `surface` — `:home | :plan | :shop | :capture | :kiosk`
- `input` — the typed input the run was started with
- `capsules_used` — the named context capsules the run requested (see §A.4)
- `tool_trace` — the ordered sequence of tool calls, args, and results
- `proposed_changes` — diff candidates produced by the loop, not yet committed
- `applied_events` — the event-store events actually appended (the reversible audit trail)
- `artifacts` — the typed `RunArtifact`s the run produced (see §A.3)
- `verification_results` — pass/fail per verifier (see §A.5)
- `model_usage` — token counts and cost rolled up across owned `AIOperations`
- `undo_payload` — set at commit time; how to revert the run's applied changes. A sum type: `:event_sourced` (compensating events on a named stream), `:snapshot` (restore captured before-images), `:composite` (children reverted in reverse order), `:irreversible` (Undo disabled, with a reason). See `docs/specs/run-receipts.md` for the encodings.
- `created_at`, `completed_at`

**Lifecycle.** A run starts in `:draft`. The harness builds the requested
capsules, dispatches the loop, and the run moves to `:running`. If the LLM
calls `ask_user` (or any human-gate tool), the run becomes `:needs_user` and
pauses — the surface shows the question, the run resumes when the user
answers. If verifiers pass and tool results commit, the run is `:applied`.
If verifiers fail unrecoverably, the run is `:failed`, no applied events
remain, and the surface shows a repair state. The user can revert an
`:applied` run to `:reverted` via its `undo_payload`, which appends
compensating events or restores snapshots — unless the payload is
`:irreversible`, in which case the receipt says so and Undo is disabled.

A `:needs_user` run the user never answers does not linger forever: the user
can discard it explicitly, and a weekly TTL sweep (`Tore.Harness.InboxSweeper`)
discards stale ones. Both paths end in `:discarded` — a terminal state with a
`discard_reason` of `:user_discarded` or `:ttl_expired`. Artifacts proposed
before the discard stay in the event stream for audit; nothing was ever
applied, so there is nothing to revert.

**Hard rules.**

- Only a `KitchenRun` may write to event-sourced aggregates (planning, shop) on the AI's behalf — direct adapter calls outside a run are forbidden.
- Every state-changing AI action shows up as a row in the kitchen runs table.

### A.3 — Runs produce `RunArtifact`s, not chat output

A `KitchenRun` does not produce a conversational reply. It produces one or
more `RunArtifact`s — typed, renderable objects with a compact summary and an
inspectable detail view. Artifacts are the contract between the harness and
the UI: the harness emits them, the UI surfaces them, and neither side knows
how the other implements its half.

**Artifact kinds:**

| Kind | Produced by | Carries |
|---|---|---|
| `PlanDiff` | `:planner_command_run`, `:weekly_planning_run` | Per-slot changes with before-and-after recipe handles |
| `GroceryDiff` | `:weekly_planning_run`, `:grocery_reconciliation_run` | Added / removed / quantity-changed items with source recipe attribution |
| `PrepGuide` | `:prep_generation_run` | Ordered prep steps tied to slots with dependencies |
| `RecipeSuggestions` | `:fridge_rescue_run`, `:planner_command_run` | Ranked recipe handles with one-line rationales |
| `RecipeProposal` | `:recipe_ingestion_run` (URL / text / photo), `:recipe_generation_run` (prompt) | A parsed-or-generated recipe shown before commit; user can edit; commit writes to catalog |
| `PantryBeliefUpdate` | `:receipt_ingestion_run`, `:pantry_belief_update_run` | Items added / removed / `last_seen_at` bumped, with provenance |
| `CostEntry` | `:receipt_ingestion_run` | Parsed receipt: store, date, total, line items, optional photo path |
| `DealsUpdate` | `:deal_capture_run` | New deals parsed from a flyer photo, with provenance `:vision` |
| `MemoryUpdate` | `:kitchen_memory_synthesis_run` | Insights added / superseded / unchanged, with evidence pointers |
| `CounterNote` | `:ambient_scan_run` | A proposed action with title, body, `proposed_run` link, primary + dismiss actions |
| `PantrySnapshot` | any run that mutates pantry rows (emitted alongside `PantryBeliefUpdate`) | Per-row before/after images (`%{item_id, before, after}`) so the `undo_payload` derived at commit time can restore rows exactly |
| `RunBundle` | `:capture_turn_run` | A parent run's manifest of the child runs it owns, so one Capture turn renders as one receipt with one Undo (a `:composite` payload over the children) |
| `RunSummary` | every run | One-line human-readable description plus structured `counts` (e.g. `%{meals_changed: 4, grocery_items_updated: 17, prep_notes_added: 1}`); always present |

**Renderable contract.** Every artifact must support two render modes:

- **Summary** — at most one short line for the run-receipt strip, plus a structured `counts` map. The UI assembles the summary string from `counts` using a small renderer (e.g. *"4 meals changed · 17 grocery items updated · 1 prep note added"*), so spacing, separators, and pluralisation are UI concerns and never the harness's prose. The harness guarantees the numbers; the UI guarantees the prose.
- **Detail** — a structured view the user opens deliberately. Example: the full `PlanDiff` shown as before-and-after slots, with a per-slot rationale.

The UI never reads run internals. It reads artifacts. A new UI surface that
wants to show, say, the planner's proposed changes opens the `PlanDiff`
artifact from the latest `:applied` run.

**No chat transcripts in artifacts.** The LLM's prose replies are recorded in
`tool_trace` for the audit log and the inspector, but are never the primary
rendering. A run that produces only a chat-shaped string with no typed
artifact is a harness bug.

**Hard rule.** Every `:applied` or `:needs_user` `KitchenRun` carries at least
one artifact (always a `RunSummary`, often a domain artifact too). A run with
zero artifacts is invalid.

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
| `HouseholdPreferencesCapsule` | Diet, allergies, dislikes, cuisines, kid constraints, default servings, planning days | `Tore.Household.get_preferences/0` |
| `ActiveInsightsCapsule` | Active `HouseholdInsight` rows, prose + structured fields | `Tore.Household.list_active_insights/0` |
| `WeekPlanCapsule` | The current or referenced week's plan state, per slot | `Tore.Planning.load_plan/1` |
| `PantryBeliefsCapsule` | Approximate inventory with `last_seen_at` and provenance; framed as belief, not fact | `Tore.Pantry.list_inventory/0` |
| `DealsDigestCapsule` | Active deals grouped by store, ranked by household affinity | `Tore.Deals.list_current/0` + `RecipeAffinityCapsule` |
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
verifier before its `applied_events` are committed. The LLM proposes. The
verifier decides if the proposal can actually land. The user sees a clean,
validated result — never a half-applied edit.

Verifiers are pure code, not LLM calls. They read the run's
`proposed_changes` and the current state of the affected aggregates, and
return either `:ok` or a structured `:fail` reason. They do not call models,
do not have side effects, and are cheap to run inline at the end of every
run.

**Verifier catalog (V1):**

| Verifier | Owns | Checks |
|---|---|---|
| `PlanVerifier` | `PlanDiff` | No locked/pinned slot was changed; every assigned recipe has servings; leftover slots point to a valid source meal earlier in the week; skipped slots are explicit, not missing; no banned ingredient or dietary constraint is violated; no recipe appears twice within the household's configured repeat window |
| `GroceryVerifier` | `GroceryDiff` | Every removed item was added by a recipe (manual user adds are never AI-removed); every added quantity has a unit; pantry deductions use approximate inventory and never assume hard zero |
| `PrepVerifier` | `PrepGuide` | Every prep step points to a slot in the current plan; prep dependencies are scheduled before the dependent meal, not after; no step references a recipe not in the plan |
| `PantryVerifier` | `PantryBeliefUpdate` | Provenance is set on every item write; no negative quantities; `last_seen_at` is monotonic per item |
| `RecipeProposalVerifier` | `RecipeProposal` | Title, ingredients (≥1), and instructions are present; servings is positive; no near-duplicate of an existing catalog recipe (title + ingredient overlap heuristic); no ingredient name is empty |
| `CostEntryVerifier` | `CostEntry` | Store, date, total are present; line items sum within tolerance of total; date is not in the future |
| `DealsUpdateVerifier` | `DealsUpdate` | Every deal has product name, price, store, source; `valid_until` is set or defaults to 14 days; no duplicate of a still-active scraped deal |
| `MemoryVerifier` | `MemoryUpdate` | New insights have `kind`, `confidence`, and `evidence_count`; superseded insights link to a successor; no more than the configured maximum active insights per household |
| `CounterNoteVerifier` | `CounterNote` | Title and body present; `proposed_run` is a declared run kind; primary action is a valid event the harness can dispatch; rationale list non-empty |

**Verifier lifecycle.** A run's loop ends. The harness collects
`proposed_changes` from the loop's `tool_trace`, runs the appropriate
verifiers, and one of three things happens:

- **All pass.** The harness commits `applied_events` to the event store, persists artifacts, transitions the run to `:applied`, and surfaces the run receipt.
- **One or more fail.** No events commit. The run transitions to `:failed`. Each verifier failure stores both a structured `code` (e.g. `:slot_locked`, `:ingredient_missing`, `:dup_recipe_in_repeat_window`) and a `user_message` field — a short, human-readable sentence that names what blocked the action without exposing tool-call internals or blaming the model. The surface shows a compact repair state with the `user_message`, a verifier-specified `repair_action` (a `proposed_run` link or a manual-edit affordance), and a dismiss option. *Example: "Tuesday dinner is locked, so nothing was changed."* (An ambiguous reference like "the salmon" matching two recipes is **not** a verifier failure — the resolver returns `:ambiguous` mid-loop and the LLM must `ask_user`, per §A.6.2. Verifiers catch proposals that cannot land; resolvers catch references that cannot be trusted.) The verifier owning the failure is responsible for both fields.
- **Run hit a human gate mid-loop.** The verifier did not get a chance to run. The run is `:needs_user`; verification happens after the user answers.

**No partial applies.** A verifier failure is atomic — nothing commits. This
is the load-bearing rule. The run is either fully applied or not applied;
the user is never asked to clean up a half-edited week.

**Concurrency and drift.** Verification and commit happen against the same
aggregate version: the verifier reads the affected streams at a version, and
the commit appends with optimistic concurrency at that version. If the
aggregate advanced in between — the user edited the plan while the run was
in flight, or another run landed first — the append is rejected and the
harness re-verifies against the new state before committing; if the proposal
no longer verifies, the run fails with the normal repair state. Runs never
hold locks and never block a user's direct edits. The same discipline applies
to revert: compensating changes are computed at revert time against current
state per the `undo_payload` kind, and a revert that can no longer be applied
safely surfaces as irreversible rather than half-reverting.

**No model retry on verifier failure.** When verification fails, the harness
does not silently re-run the LLM with the verifier reason in the prompt.
That path is tempting (cheap retry, often fixes the failure) but it hides
bugs and produces non-deterministic spend. The repair state is surfaced to
the user; they decide whether to retry.

**Hard rules.**

- Every run kind that produces a state-changing artifact has at least one verifier in this table. A run kind that doesn't is a harness bug.
- Verifiers run inside the harness, not inside the LLM tool layer. The LLM never sees verifier failure reasons during a run.
- Verifier failures are stored on the `KitchenRun` row for later inspection; a verifier that fails 20% of the time across runs is a signal to fix the tool, the prompt, or the verifier — not to retry harder.

### A.6 — Risk tiers, resolved references, and Kitchen Skills

#### A.6.1 — Risk tiers

Every `KitchenRun` kind is classified into one of four tiers. The tier
determines whether the harness auto-applies, surfaces for inspection, or
requires explicit confirmation before any event commits.

| Tier | Examples | Apply policy |
|---|---|---|
| **Tier 0 — Surface only** | `:ambient_scan_run`, `:fridge_rescue_run` | The run produces surface-only artifacts (`CounterNote`s, `RecipeSuggestions`) but writes no aggregate state on its own. The user opts in by tapping a primary action, which dispatches a follow-up run of higher tier. |
| **Tier 1 — Reversible domain edits** | `:planner_command_run`, `:weekly_planning_run`, `:prep_generation_run`, `:pantry_belief_update_run`, `:kitchen_memory_synthesis_run` | Auto-apply after verifier passes. The run receipt is visible. Undo is one tap. |
| **Tier 2 — Reversible ingestion** | `:receipt_ingestion_run`, `:deal_capture_run`, `:recipe_ingestion_run`, `:grocery_reconciliation_run` | Auto-apply by default, but the proposal artifact is always surfaced as a card the user can review and edit before commit. Becomes `:needs_user` per the rule below. |
| **Tier 3 — Destructive or sensitive** | `:recipe_generation_run`; bulk operations like *clear the week*; any change touching dietary constraints or allergens | Never auto-applies. Proposal is produced; commit requires explicit user confirmation. `:recipe_generation_run` sits here deliberately: ingestion transcribes a recipe that exists somewhere, generation invents one — invented content never enters the catalog without an explicit look. |

A Tier 2 run becomes `:needs_user` (proposal surfaced as an editable card
before commit) when **any** of the following holds:

- **Item count.** The proposal touches more than 5 line items.
- **Confidence.** Any item in the proposal has resolver confidence below 0.8 (the resolver-handle threshold from §A.6.2 is 0.7 for action-tool acceptance; 0.8 is the higher bar for trust-without-review).
- **Provenance.** The run's input was a `:vision` source (photo) rather than `:scrape` or `:manual`.

**Hard rules.**

- Tier classification lives on the run-kind declaration. It is not a runtime decision; the model cannot escalate or de-escalate.
- Tier 3 is the only tier with a confirm modal. Tier 0–2 use act-then-undo. The UI never asks "are you sure?" for Tier 1 or 2.
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
Orchestrator when a run is scoped to a slot the user opened in the UI, e.g.
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

A Kitchen Skill is a reusable agent runbook: a pre-declared `KitchenRun`
kind with its capsules, tools, verifier, and target artifact set. Skills are
how the user invokes a higher-order operation without typing a free-text
command.

Each skill is a small typed declaration. The skill catalog is the V1 surface
of the harness for ordinary household operations.

**V1 skill catalog:**

| Skill | Dispatches | Purpose |
|---|---|---|
| `PlanMyWeek` | `:weekly_planning_run` | Generate the upcoming week from current pantry, deals, insights, and past affinity |
| `UseTheDeals` | `:weekly_planning_run` (deal-weighted) | Re-plan the week prioritising current active deals |
| `LowEnergyWeek` | `:weekly_planning_run` (low-effort weighted) | Plan a week of short-cook recipes with cascading leftovers |
| `StretchLeftovers` | `:planner_command_run` | Re-arrange the current week to maximise leftover cascades |
| `RescueTheFridge` | `:fridge_rescue_run` | Photo or pantry snapshot → recipe suggestions that use what's there |
| `SundayPrep` | `:prep_generation_run` | Generate a prep guide for the upcoming week |
| `FinishTheShoppingList` | `:grocery_reconciliation_run` | Reconcile grocery list with the plan and add anything missing |
| `LearnFromThisWeek` | `:kitchen_memory_synthesis_run` | Force an out-of-schedule memory synthesis from recent events |

The runbook fields (`trigger`, `capsules`, `tools`, `verifier`, `artifact`,
`surface`) live in a future Skills sub-spec. The umbrella names the concept
and the V1 list only.

**Surface rule.** Skills appear in the UI as small contextual action chips
on the surfaces where they are relevant (e.g. `PlanMyWeek` on Plan;
`RescueTheFridge` on Capture). There is no global "skills" management screen.

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
- A `CounterNote` carries an `evidence` list: `["yoghurt last seen 6 days ago", "chicken marinade recipe uses yoghurt", "chicken slot empty Wednesday"]`.
- A `RecipeSuggestion` carries a `rationale` per recipe: `["uses leftover salmon", "30 min total", "household chose this 3× in the last 8 weeks"]`.
- A `PantryBeliefUpdate` carries `provenance` per item: `:receipt`, `:grocery_checkoff`, `:shelf_photo`, `:manual`.

Rationale strings are produced by the run, not by the LLM at render time.
They reflect what actually drove the decision: the capsule fields the model
read, the deals it weighted, the insights it cited. A rationale that says
only *"the model picked it"* is a harness bug.

**UI contract.** The surface always renders the artifact's summary form by
default. The rationale and evidence are revealed on a deliberate inspect
gesture. The harness guarantees the data is there; UI/UX spec decides the
affordance.

**Hard rules.**

- Every artifact field that surfaces a decision carries a rationale or provenance.
- Rationales are short and concrete — not paragraphs, not LLM prose. The verifier owning the artifact checks rationale presence as part of artifact validity.
- A run that produces an artifact with empty rationales fails its verifier. There is no "the model didn't explain" fallback.

### A.8 — Model routing

The harness routes LLM calls to one of three model tiers based on the
callback's pattern (§LLM Interface Conventions) and the run kind's risk tier
(§A.6.1). Routing is per-callback, not per-feature. The model used on each
call is recorded on `AIOperations.model` for cost telemetry.

**Model tiers (V1):**

| Tier | Use cases | Default model class |
|---|---|---|
| **Cheap structured** | Pattern A callbacks that parse, classify, or summarise: `classify_image`, `parse_receipt_image`, `parse_pantry_image`, `parse_deals_image`, `cook_mode_steps`, ambient-scan summarisations, capsule `to_prompt/1` token reductions | A fast small model with reliable strict-JSON support |
| **Strong tool-capable** | Pattern B `chat_with_tools/4` for `:planner_command_run`, `:weekly_planning_run`, `:grocery_reconciliation_run`, `:fridge_rescue_run`, and any future skill-driven run that calls multiple tools across multiple turns | A frontier tool-calling model |
| **Vision** | Any callback whose primary input is an image: `classify_image`, `parse_receipt_image`, `parse_recipe_image` (when input is a photo), `parse_pantry_image`, `parse_deals_image`, `identify_fridge_contents` | A vision-capable model; may overlap with "cheap structured" when the structured-output is small |

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
- `AIOperations.model` is set on every row. Cost rollups on `KitchenRun.model_usage` aggregate by tier across the run's owned operations.
- The schema-failure single-retry path is the only place the harness silently uses a different model than the callback declared. The retry is logged distinctly (`AIOperations.kind` ends with `.retry`). The monthly `SpendGuard` cap remains the runaway-cost guard.

### A.9 — Meeting point with docs/UI_SPEC.md

This spec owns the harness contract: run kinds, artifact shapes, capsule
declarations, verifier checks, risk tiers, resolver handles. `docs/UI_SPEC.md`
owns the surface contract: how artifacts render across Today / Plan / Shop /
Capture / Cooking / Kiosk / Settings, the visual system, the run-receipt and
thinking-state and failure-state and undo and "Why this?" patterns.

The two specs meet at artifact schemas. Concretely:

- `RunSummary.counts` (§A.3) drives UI_SPEC §7.1's run-receipt pluralisation and §5.2's receipt card body.
- `KitchenRun.phase` (§A.2) drives UI_SPEC §7.2's operational thinking-state strip.
- Verifier failures' `user_message` + `repair_action` (§A.5) drive UI_SPEC §7.3's failure-state card.
- Per-item `rationale` and `evidence` on every artifact (§A.7) drive UI_SPEC §7.5's "Why this?" expansion.
- `CounterNote` fields `title`, `body`, `primary_action`, `dismiss_action` (§A.3) drive UI_SPEC §5.2's counter-note card.
- `RecipeProposal` fields drive UI_SPEC §6.4's capture-result preview.
- `MemoryUpdate.evidence_count` drives UI_SPEC §5.2's memory card "Seen 7 times" line.

When UI_SPEC adds a surface that needs an artifact field this spec didn't
name, that's a SPEC.md amendment, not a UI-side workaround. When this spec
declares a field that no UI surface consumes, that's a SPEC.md trimming
opportunity. Both specs evolve together at the artifact-schema boundary; no
side silently degrades.

**Boundary additions (2026-07, anticipation layer):**

1. Deal product identity fields on grocery/shop items — `product_label`, `package_size`, `price`, `store` — so a matched deal can render against the specific product it applies to.
2. `CounterNote` gains `surface` targeting (`:today | :plan | :shop`, matching `KitchenRun.surface`) and a `proposed_run` descriptor (the run kind + scope dispatched on primary action).
3. The new `CounterNote` kinds — `swap_suggestion`, `freezer_fallback`, `missing_ingredient`, `usual_item_missing`, `deal_match`, `plan_repair` — see §3's catalog.
4. `:ambient_scan_run` re-triggers on plan/pantry mutation, not only the daily cron: a debounced mutation trigger fires the scan after a plan or pantry write settles.

Receipt seen-state (the review pill surfacing unread run receipts) is
already shipped — not re-specified here.

---

## The Six LLM-Native Features

Each feature is re-described here as one or more `KitchenRun` kinds with their
capsules, tools, artifacts, verifier, risk tier, and model tier. All six are
required; none is optional.

Run kinds that appear in the harness tables but are not specified in this
section — `:recipe_ingestion_run`, `:recipe_generation_run`,
`:deal_capture_run`, `:grocery_reconciliation_run`, `:prep_generation_run`,
and the `:capture_turn_run` parent kind — get their full declarations in
sub-specs when picked up. Until then, the artifact table (§A.3), the tier
table (§A.6.1), and the skill catalog (§A.6.3) are their only contract.


### 1. Longitudinal Learning → `:kitchen_memory_synthesis_run`

A weekly Quantum job (Sat 06:00) starts a `:kitchen_memory_synthesis_run`. It
reads the planning event stream from the last 28 days and produces a small set
of typed observations about how the household actually eats.

- **Capsules:** `ActiveInsightsCapsule`, `RecentHistoryCapsule`, `RecipeAffinityCapsule`.
- **Tools:** none — Pattern A structured-output call.
- **Artifact:** `MemoryUpdate` (insights added / superseded / unchanged, with evidence pointers per insight).
- **Verifier:** `MemoryVerifier` (kind, confidence, evidence_count present; max active count respected; superseded insights link forward).
- **Tier:** 1 — reversible. Dismissed insights are tombstoned; follow-up synthesis won't recreate them.
- **Model tier:** cheap structured.

Inputs the synthesis considers: `MealSkipped` events grouped by weekday →
*"skips Thursdays 7/10 weeks"*; `RecipeRemoved` and `RecipeSwapped` → dislikes
and friction; `LeftoverDay` patterns → which cascades survive; slot fill rate
by week → *"rarely plans past Wednesday"*.

Storage: `household_insights` table — small (max ~10 active observations per
household), with structured fields (`kind`, `subject`, `claim`,
`evidence_count`, `confidence`, `last_evidence_at`) plus a prose `prompt_text`
used by capsules. A `dismissed_at` field tombstones rather than deletes; a
`superseded_by_id` link preserves history.

The user sees the active insights on Settings → Kitchen Memory and can dismiss
any insight that's wrong.

**Hard rule:** There is no rating UI. There is no *"how was dinner?"* prompt.
The event stream is the only signal.

### 2. Natural-Language Planner → `:planner_command_run`

The user types into the planner command bar. The harness starts a
`:planner_command_run`.

- **Capsules:** `HouseholdPreferencesCapsule`, `ActiveInsightsCapsule`, `WeekPlanCapsule`, `PantryBeliefsCapsule`, `DealsDigestCapsule`, `RecentHistoryCapsule`.
- **Tools:** resolver tools (`resolve_slot`, `resolve_recipe`, `resolve_grocery_item`); action tools that take handles (`assign_recipe`, `swap_recipe`, `skip_meal`, `mark_leftover`, `set_servings`, `remove_recipe`); read tools (`search_recipes`, `pantry_snapshot`, `active_deals`); terminal `ask_user`.
- **Artifacts:** `PlanDiff` (always), `RecipeSuggestions` (when a read tool surfaces candidates), `RunSummary`.
- **Verifier:** `PlanVerifier`.
- **Tier:** 1 — auto-apply with undo. The run receipt is the user-facing confirmation.
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

### 3. Proactive Intelligence → `:ambient_scan_run`

A daily Quantum job (07:00 in the original design; **shipped at 05:00**, see
below) starts an `:ambient_scan_run`. A post-scrape trigger (after the
weekly deal scrape completes) starts a `:deal_opportunity_run` (not yet
implemented). Both produce `CounterNote` artifacts.

- **Capsules:** `WeekPlanCapsule`, `PantryBeliefsCapsule`, `DealsDigestCapsule`, `RecentHistoryCapsule`, `RecipeAffinityCapsule`, `ActiveInsightsCapsule`.
- **Tools:** none — Pattern A structured-output calls.
- **Artifacts:** zero or more `CounterNote`s, each with `kind`, `title`, `body`, `proposed_run` (the run kind dispatched when the user taps the primary action), primary + dismiss actions, and an evidence list.
- **Verifier:** `CounterNoteVerifier`.
- **Tier:** 0 — surface only. The runs never mutate aggregate state. State mutation happens when the user taps the primary action, which dispatches a follow-up Tier 1+ run with `started_by: :counter_note_followup`.
- **Model tier:** cheap structured.

**`CounterNote` kinds (V1 design):**

| kind | surface | trigger | proposed_run |
|---|---|---|---|
| `swap_suggestion` | `today`/`plan` | busy-day insight × heavier dish on that slot | `:planner_command_run` scoped to the slot |
| `freezer_fallback` | `today` | busy-day insight × freezer belief matching tonight | `:planner_command_run` ("use the frozen …") |
| `missing_ingredient` | `today` | pantry belief says an ingredient of tonight's recipe is absent | `:planner_command_run` (add substitute / add to list) |
| `usual_item_missing` | `shop` | purchase-history staple not on the current list | `:planner_command_run` (add item) |
| `deal_match` | `shop`/`plan` | active deal matches a planned recipe/list item | `:planner_command_run` (use the deal) |
| `plan_repair` | `plan` | empty/broken slot detected | `:weekly_planning_run` slot-fill |

New kinds are added by extending the catalog, not by new run kinds.

**`CounterNote` scan kinds (shipped, 2026-08).** The ambient scan (below)
implements a different, shipped-first catalog of four kinds — the table
above is the original design; this is what the scan actually proposes:

| Kind | Trigger | `proposed_run` shape |
|---|---|---|
| `swap_suggestion` | A hard slot on a busy day has an easier alternative elsewhere in the week | `%{"kind" => "planner_command", "command" => "...", "scoped_slot" => slot_key}` — `scoped_slot` required |
| `freezer_fallback` | A frozen leftover (pantry belief) fits a busy slot | `%{"kind" => "planner_command", "command" => "...", "scoped_slot" => slot_key}` — `scoped_slot` required |
| `missing_ingredient` | Tonight's assigned recipe needs something pantry beliefs say is absent | `%{"kind" => "planner_command", ...}` (command optional) or `nil` (informational) |
| `usual_item_missing` | A habitual purchase is absent from the current shopping list | `%{"kind" => "add_item", "name" => "...", "quantity" => nil \| String.t(), "unit" => nil \| String.t()}` — deterministic, no LLM run on follow-up |

`proposed_run` is a map column on `CounterNote` with a `"kind"`
discriminator — `"planner_command"` (dispatched via `:planner_command_run`,
`started_by: "counter_note_followup"`, scoped per §A.6.2/Plan-2's
`scoped_slot`), `"add_item"` (applied directly via `Shop.add_item` — code
disposes, no LLM run for a deterministic add), or `nil` (informational,
today's non-scan behavior unchanged).

**Verified-before-materialize pipeline.** Each raw LLM proposal is checked
by `CounterNoteVerifier` (surface ∈ `home/week/groceries`; kind ∈ the four
scan kinds; non-blank/length-capped title and body; `scoped_slot` — when
present — a member of the week's slot-key domain, required for
`swap_suggestion`/`freezer_fallback`; `command` optional; `usual_item_missing`
requires an `item`) before it is ever inserted. Failures are dropped
silently — an invalid proposal never reaches the user. Survivors are capped
at one note per surface (first wins) and written via
`CounterNotes.replace_scan_notes/1`, which expires the previous pending
scan-kind batch and inserts the new one in a single transaction — manual and
informational notes are untouched. `expire_stale/0` runs daily on cron
independent of the scan, so a note nobody acts on ages out.

**Hard rule.** `CounterNote`s appear inline on the relevant surface. They are
never delivered as push, email, or any other interruption.

**`:ambient_scan_run` (shipped, 2026-08).** Tier 0, headless, modeled 1:1 on
`:kitchen_memory_synthesis_run`: capsules
(`WeekPlanCapsule`/`PantryBeliefsCapsule`/`ActiveInsightsCapsule`/
`RecentHistoryCapsule`, plus a serialized current shopping list and a
"recently dismissed — do not re-propose" section built from
`CounterNotes.recently_ignored/1`) → one `Tore.LLM.text` call → verify each
note against `CounterNoteVerifier` → materialize via
`replace_scan_notes/1`. `started_by: "system"`. Gated by SpendGuard feature
`:ambient_scan` (`{8_000, 600}` — 8,000-token budget, 600 s cooldown as the
storm backstop); usage is logged to both the `Run` and SpendGuard.
Triggers: Quantum daily at 05:00 (`expire_stale/0` runs at 04:30, just
before), plus a 5-minute-debounced re-trigger after `"plan"`/`"shop_list"`
PubSub mutations settle (`Tore.Harness.AmbientScan.Debouncer`). Dismissing a
note (Rule 3, UI_SPEC §2.3) is fed back into the next scan's prompt so the
model does not re-propose it.

### 4. Pantry as Inference → `:pantry_belief_update_run`

Every implicit channel that updates pantry inventory dispatches a
`:pantry_belief_update_run`: grocery item checked off, shelf photo captured,
manual edit in Settings.

- **Capsules:** `PantryBeliefsCapsule` (the current state, framed as belief).
- **Tools:** vision callback `parse_pantry_image/1` for photo inputs; no tools for grocery checkoff (the run is deterministic in that case).
- **Artifact:** `PantryBeliefUpdate` (items added / removed / `last_seen_at` bumped, each with `provenance` ∈ `:receipt | :grocery_checkoff | :shelf_photo | :manual`).
- **Verifier:** `PantryVerifier`.
- **Tier:** 1 (grocery checkoff, manual) or 2 (shelf photo — vision input → editable card surfaces if ≥5 items or low confidence per §A.6.1).
- **Model tier:** vision (photo input only).

**Demotion in detail (still required):**

- The `/pantry` route is removed from main nav.
- `pantry_live.ex` is a read-only *"Here's what we think you have"* view reachable from Settings. One action: remove an item. No add. No edit.
- Adding to the pantry happens via three implicit channels: checked-off grocery items, parsed receipts (§5), photo-of-shelf via Capture.
- The `PantryBeliefsCapsule` frames inventory as approximate. Items carry `last_seen_at` and `provenance`. A capsule that says *"the household has olive oil"* is replaced by *"probably has olive oil, last seen 3 weeks ago via receipt"*.

**Hard rule.** Spec or implementation work that adds back a primary
pantry-management screen is a regression of this requirement.

### 5. Receipt → Pantry Closed Loop → `:receipt_ingestion_run`

A receipt photo uploaded through Capture dispatches a `:receipt_ingestion_run`.

- **Capsules:** none — the input is the image; no household state required for parsing.
- **Tools:** `parse_receipt_image/1` (vision). The run then dispatches a sub-write: cost log + pantry write.
- **Artifacts:** `CostEntry` (the parsed receipt) AND `PantryBeliefUpdate` (each line item with `provenance: :receipt`) — both from one run.
- **Verifiers:** `CostEntryVerifier` AND `PantryVerifier`. Either failure fails the whole run; atomic apply (§A.5).
- **Tier:** 2 — auto-apply if ≤5 line items AND confidence ≥0.8 per §A.6.1; otherwise `:needs_user` with editable line-item card.
- **Model tier:** vision.

This is the closed loop: one user action (upload photo), two outputs
(`CostEntry` + `PantryBeliefUpdate`), one verifier set, one undo button.

### 6. Fridge Photo → Suggestions → `:fridge_rescue_run`

A Capture photo classified as `:fridge` dispatches a `:fridge_rescue_run`.

- **Capsules:** `HouseholdPreferencesCapsule`, `WeekPlanCapsule` (so suggestions don't duplicate tonight's plan), `RecipeAffinityCapsule`.
- **Tools:** `identify_fridge_contents/1` (vision); `search_recipes` (read); `assign_recipe` (action, optional — user may tap *"add to tonight"* from a suggestion).
- **Artifact:** `RecipeSuggestions` (3 ranked recipes with rationale).
- **Verifier:** none for the suggestions themselves (Tier 0 — read-only). If the user taps *"add to tonight,"* a follow-up `:planner_command_run` dispatches with `PlanVerifier`.
- **Tier:** 0 — purely informational.
- **Model tier:** vision (initial photo) + strong tool-capable (suggestion ranking).

The pre-harness capture flow replied *"Want me to suggest some recipes?"* and
stopped. The harness completes the run and surfaces the `RecipeSuggestions`
artifact inline.

---

## Interfaces

### Kiosk (`/kiosk`)

The kiosk is intentionally narrow.

**Primary surface:**
- Tonight's recipe card: name, image, servings, total time, "Start cooking" button (→ `/kiosk/cooking/:id`).
- Components already prepped (cross-referenced with `prep` state).
- One-line counter note if any is active for surface `kiosk`.

**Secondary:**
- A horizontal strip showing the next 3 days' planned meals. No interaction beyond "look at it."
- A button to open Kiosk Capture (`kiosk_capture_live.ex`) — a deliberately restricted assistant that only answers cooking/recipe questions (not planning, not pantry edits).

**Hard rules:**
- No week calendar on the kiosk root.
- No plan editing on the kiosk. Planning happens on phone/laptop.
- No "report back" UI on the prep guide. The prep guide is a document you read.

### Home (`/`)

The phone/laptop landing surface, distinct from the planner.

- Tonight + tomorrow card pair.
- Active counter notes for surface `home`.
- A week strip showing this week's plan at a glance.
- FAB → `/capture`.

### Planner (`/plan`)

- Week view with editable slots.
- Counter notes for surface `plan` at the top.
- A command bar at the bottom: text input + voice (phase ≥ 8) that runs through `PlannerAgent` (§2).
- Slot interactions still work via tap (assign, swap, skip, mark leftover, set servings).

### Capture (`/capture`)

Full-screen capture surface that accepts text and photos. Photos are classified
(`receipt | recipe | pantry_items | fridge | unknown`) and routed to the
appropriate run kind. The capture surface is a way to start a `KitchenRun`,
not a conversation thread: each capture produces a typed artifact (see §A.3)
and the surface renders it, not a chat reply.

A single Capture turn that produces multiple state changes is wrapped in a
`:capture_turn_run` — a parent run whose `RunBundle` artifact lists the child
runs, so the turn renders as one receipt with one Undo (a `:composite`
payload over the children).

### Shop (`/shop`)

The reliability anchor. Manual add always works. Plan changes broadcast to
update the list automatically, but the list survives a missing plan, a
missing pantry, and a missing connection to the LLM. Checking an item
dispatches a `:pantry_belief_update_run` (see §4).

### Settings (`/settings`)

- Family preferences (diet, cuisines, kid constraints, weekly cadence).
- **Kitchen Memory:** the list of active family insights with per-insight "this is
  wrong" buttons that dismiss without deletion.
- Read-only pantry view ("Here's what we think you have"), reachable from here.
- Device tokens for kiosks.
- Per-user accounts.

### Costs (out of main nav)

Reachable from Settings → "Spending." Not weekly viewing. The receipts table and
monthly totals stay; the dashboards drop in priority.

---

## Removed in Rewrite

The following exists in the codebase today and is **deleted** by this spec. Implementation
plans must remove these explicitly — they are not deprecated, they are gone.

| Removed | Replacement |
|---------|-------------|
| `pantry_live.ex` full CRUD (add/edit/category management UI) | Read-only inferred pantry view in Settings; receipt + grocery + photo-scan auto-add |
| `/pantry` in main nav | Removed entirely |
| `/costs` in main nav | Moved under Settings |
| `Tore.Family` context (introduced as the canonical name in the prior rewrite) | `Tore.Household` is canonical; `Tore.Family.*` deleted |
| `CounterNotes.build_home_note/1` hardcoded "Ready to cook tonight?" string | `AmbientScan` daily job |
| Two-step `confirm_receipt` UI as the only receipt → pantry path | Auto-add by default; confirm flow stays only for explicit "review before saving" |
| Onboarding questionnaire (if/when added) | Inference from events over time |
| Any meal-rating or "how was dinner?" UI | Never built; explicitly prohibited |
| Any "you haven't logged in N days" reminder | Never built; explicitly prohibited |

---

## Module Map (target state)

Files marked `PLANNED` are named by this spec but not yet in the tree;
everything else reflects the code as of 2026-07-03.

```
lib/tore/
  household.ex               # canonical household context (preferences, members, insights)
  household/
    household_schema.ex
    household_insight.ex
    preferences.ex
  accounts.ex                # users, sessions, device tokens
  recipes.ex                 # catalog; owns scrape_and_create/generate_image (folded)
  deals.ex                   # owns scrape_all/scrape_url + store parsers (folded)
  pantry.ex                  # inference-shaped: list, add_item, remove_item, last_seen_at, belief decay
  costs.ex                   # receipts, dining out, LLM usage; closes loop to pantry
  prep.ex                    # owns generate_guide (folded)
  planning.ex                # imperative shell over the pure Planning aggregate
  planning/                  # Decider aggregate
    commands.ex              # AssignRecipe, SwapRecipe, SkipMeal, ...
    events.ex                # MealSkipped, RecipeRemoved, RecipeSwapped, ...
    decider.ex
    state.ex
  shop.ex                    # imperative shell over the pure Shop aggregate
  shop/                      # Decider aggregate
  counter_notes.ex           # context for CounterNote artifacts
  counter_notes/
    counter_note.ex
  ai_operations.ex           # low-level LLM call audit log; owned by KitchenRun
  capture/                   # Capture surface plumbing: router, uploads, dispatch
  harness/                   # the Agent Harness Layer
    run.ex                   # KitchenRun context (open, transition, revert)
    run/                     # the Run Decider aggregate: one event stream per run
      commands.ex
      decider.ex
      events.ex
      state.ex               # Draft | Running | NeedsUser | Applied | Failed | Reverted | Discarded
    orchestrator.ex          # dispatches declared run kinds end-to-end
    run_receipts.ex          # receipt projection + atomic revert
    undo_payload.ex          # :event_sourced | :snapshot | :composite | :irreversible
    diff_row.ex              # cross-surface diff shape rendered on receipts
    inbox_sweeper.ex         # weekly TTL sweep: stale :needs_user → :discarded
    projector.ex             # + projector_registry.ex, projector_supervisor.ex
    kitchen_memory_synthesis.ex  # §1 run implementation
    receipt_ingestion.ex         # §5 run implementation
    pantry_update.ex             # §4 apply/revert helper
    plan_diff_builder.ex
    artifact.ex              # RunArtifact behaviour + artifact/registry.ex
    artifact/                # plan_diff, pantry_belief_update, pantry_snapshot,
                             # cost_entry, memory_update, run_summary, run_bundle
    capsule.ex               # capsule behaviour; capsules.ex assembles per-run capsule lists
    capsules/                # 6 landed; deals_digest_capsule + cost_intent_capsule PLANNED
    verifier/                # plan, pantry, cost_entry, memory landed; grocery, prep,
                             # recipe_proposal, deals_update, counter_note PLANNED
    run_kinds.ex             # PLANNED: static run-kind declarations (capsules, tools, verifier, tier, model_tier)
    skills.ex                # PLANNED: V1 Kitchen Skills catalog
    resolvers.ex             # PLANNED: resolve_slot, resolve_recipe, resolve_grocery_item, resolve_pantry_item
    handles.ex               # PLANNED: ResolvedSlot, ResolvedRecipe, etc.
    ambient_scan.ex          # PLANNED: daily rule scan; dispatches :ambient_scan_run
  llm.ex                     # facade: text/3, vision/4, chat/3, chat_with_tools/4
  llm/
    spec.ex                  # wire-spec behaviour: provider body shape behind the facade
    openai.ex                # OpenAI-compatible Spec implementation
    prompts.ex               # JSON schemas + prompt templates (Pattern A operations)
    planner_agent.ex         # tool-calling loop runtime; emits into a KitchenRun
    planner_tools.ex         # tool definitions (target state: handles, not raw IDs)
    tool.ex                  # declarative tool struct
  adapters/
    open_router.ex           # transport adapter
  spend_guard.ex
  scheduler.ex
  storage.ex
```

```
lib/tore_web/live/
  home_live.ex
  planner_live.ex            # command bar drives PlannerAgent
  capture_live.ex            # capture → run dispatch → artifact rendering
  inbox_live.ex              # run-receipt inbox (projection over Run streams)
  run_review_live.ex         # :needs_user review + receipt detail
  kiosk_live.ex
  kiosk_capture_live.ex
  cooking_live.ex
  shop_live.ex               # check → :pantry_belief_update_run
  recipe_live.ex
  deals_live.ex
  prep_live.ex
  settings_live.ex           # kitchen memory + read-only pantry
  login_live.ex
  setup_live.ex
  # REMOVED: pantry_live.ex from main routing (kept only as Settings-reachable read-only view)
  # MOVED: cost_live.ex under settings scope
```

---

## LLM Surface

Every LLM call goes through the `Tore.LLM` facade and is logged to `AIOperations`
with a correlation ID. The facade exposes four transport callbacks, defined by
the `Tore.LLM.Spec` behaviour (a Spec encodes one provider's body shape;
`Tore.Adapter` carries the transport):

| Callback | Purpose |
|----------|---------|
| `text/3` | System + user prompt → strict-JSON structured output (Pattern A, text input) |
| `vision/4` | Image/PDF blobs + prompts → strict-JSON structured output (Pattern A, vision input) |
| `chat/3` | Multi-turn messages → prose reply (Kiosk Capture Q&A only) |
| `chat_with_tools/4` | Tool-calling chat. Powers `PlannerAgent` (§2) and every Pattern B run. |

Purpose-level operations are **not** behaviour callbacks. Each one — parse a
receipt, parse a recipe, parse a shelf photo, classify an uploaded image,
identify fridge contents, synthesise insights, suggest a recipe, compress
cook-mode steps — is a prompt + JSON-schema pair in `Tore.LLM.Prompts`,
invoked through `text/3` or `vision/4`. Adding an operation adds a prompt
spec, not a callback. (The earlier draft's `generate_plan/1` callback is
gone: weekly planning is a Pattern B tool-calling run, §A.8.)

**Spend guard:** `Tore.SpendGuard` continues to gate every LLM call. The monthly
budget is enforced at the adapter boundary. Each iteration of a `chat_with_tools`
loop is counted as a separate call against the budget.

---

## LLM Interface Conventions

Two patterns, used deliberately:

### Pattern A — Structured Output (default for parsers and extractors)

Used by every operation whose job is *"turn this input into a fixed-shape result"*:
`parse_receipt_image`, `parse_recipe_image`, `parse_pantry_image`,
`identify_fridge_contents`, `synthesise_insights`, `suggest_recipe`,
`cook_mode_steps`. All go through `text/3` or `vision/4`.

- Implementation: OpenAI-compatible `response_format: %{type: "json_schema", json_schema: %{name:, strict: true, schema:}}`.
- Schemas live in `Tore.LLM.Prompts` next to the prompt EEx files.
- `strict: true` is mandatory — the adapter must reject any non-conforming output rather than best-effort parsing.
- One LLM round-trip per call. No loops. No tool registration.

### Pattern B — Tool-Calling Agent (for in-app actions)

Used when the LLM needs to *do something* in the app — read state, then write state,
possibly across several turns. V1 has one consumer: `PlannerAgent` (§2). Future
candidates (grocery agent, prep agent) reuse the same pattern.

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
- Every call is gated by `Tore.SpendGuard` at the adapter boundary.
- No LLM-emitted SQL, no LLM-emitted code execution, no LLM-emitted shell. Tool surface is the only side-effect channel.
- System prompts are assembled from the run's declared context capsules (§A.4). There is no shared prompt builder; a call without a declared capsule list gets no household context at all.

---

## Quantum Schedule (target state)

```elixir
config :tore, Tore.Scheduler,
  jobs: [
    {"0 7 * * *",   {Tore.Harness.AmbientScan,              :run,                []}},  # PLANNED: dispatches :ambient_scan_run
    {"0 3 * * *",   {Tore.Deals,                            :clear_expired,      []}},
    {"0 4 * * 0",   {Tore.Harness.InboxSweeper,             :sweep_weekly,       []}},
    {"0 6 * * 6",   {Tore.Harness.KitchenMemorySynthesis,   :synthesise_weekly,  []}},  # dispatches :kitchen_memory_synthesis_run
    {"0 8 * * 6",   {Tore.Deals,                            :scrape_all,         []}},
    {"0 18 * * 6",  # dispatches :weekly_planning_run via the orchestrator
     ...},
    {"30 18 * * 6", # dispatches :prep_generation_run via the orchestrator
     ...},
  ]
```

**Scheduled jobs go through the harness.** A cron job that writes state on the
AI's behalf dispatches a `KitchenRun` (with `started_by: :scheduler`) — it never
calls a context function directly, per §A.2's hard rule. The current config's
direct `Tore.Planning.plan_upcoming_week` and `Tore.Prep.generate_guide` calls
are migration debt: they predate the harness and move onto orchestrator
dispatches as those run kinds land. `Tore.Deals.clear_expired` and
`scrape_all` are deterministic maintenance, not AI actions, and stay direct.

The old `home_note` job (Tore.Jobs.HomeNote, 06:00) is **removed** — `AmbientScan`
subsumes it.

---

## Auth and Multi-Tenancy

A *household* owns all data: plans, groceries, pantry, costs, insights.
*Users* belong to a household. A user is created with a 16-digit code; sessions are long-lived browser cookies.
*Kiosks* authenticate with a per-device token, scoped to one household.
`Tore.Household` is the canonical context. There is no `Tore.Family` module.

**Single-household deployment.** Tore is self-hosted for one family; there is
no plan to serve multiple households from one instance. The schema carries
`household_id` throughout so the data model stays honest, but context
functions may assume the single household (the 0-arity capsule sources in
§A.4 are deliberate, not an oversight). Multi-household support is out of
scope and must not drive API design.

---

## Backlog

Loose ideas captured here so they don't drift in a scratch file. Promote to a
proper section or sub-spec when picked up.

- **Locale on scraped recipes.** Scraped recipes should be translated into the household's locale at ingestion time.
- **Per-household OpenRouter API key.** Set via an admin page in Settings. The app is unusable (every LLM-gated surface disabled) until a key is entered.
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

1. The six LLM-native features (§1–§6) each pass an end-to-end test on a real device.
2. `pantry_live.ex` no longer offers add/edit; the route is gone from main nav.
3. `cost_live.ex` is reachable only through Settings.
4. `Tore.Family.*` is deleted; `Tore.Household` is canonical.
5. `PlannerAgent` runs a bounded tool-calling loop driven from the planner command bar, with all action tools wired through `Tore.Planning` and at least two read tools (`search_recipes`, `pantry_snapshot`) wired to real context state.
6. `AmbientScan` runs daily and writes at least one counter-note type when the
   corresponding rule fires.
7. Receipts uploaded via Capture write to both `costs` and `pantry` without a confirm
   step (the confirm path remains for explicit review).
8. Fridge photos return three concrete recipe suggestions.
9. A user can skip a meal with one tap and the app says nothing back.
10. No notifications. No nags. No streaks.
11. Every state-changing AI action is a `KitchenRun` — visible as a row in the kitchen runs table, owning its `AIOperations` rows, carrying its declared capsules, producing its typed artifacts, gated by its verifier, classified into a risk tier. No code path mutates an event-sourced aggregate on the AI's behalf outside a run.
12. Every Tier 1+ run produces at least one `RunArtifact` (always a `RunSummary`, often a domain artifact) with rationale-or-provenance fields populated. A run that produces empty rationales fails its verifier and does not commit.
