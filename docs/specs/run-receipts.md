# SPEC_FEAT_run_receipts — Reversible agent actions with run receipts

> Companion to SPEC.md (§Agent Harness) and UI_SPEC.md (§7.1, §16).
> This spec defines the backend work that makes the doctrine in UI_SPEC §16
> actually buildable.

## Status

- **Created:** 2026-06-24
- **Model:** agent acts immediately; user undoes if wrong.
  Not approval-gated proposals. Trust comes from visibility + reversibility.
- **Scope:** the BE artifacts and machinery the UI needs in order to render
  run receipts, support Undo, surface belief states, and respect user locks.
- **Out of scope:** the UI work itself (UI_SPEC owns that), the Today/Plan/Shop
  visual rebuild (separate phase).

### Relationship to the KitchenRun harness (SPEC.md §A)

This spec is **a vertical slice of the KitchenRun harness**, focused on the
user-visible half: the receipt, the diff, the undo. It is not a parallel
track or a replacement — it is the first concrete run kind, shipped before
the full harness (capsules, verifiers, resolvers, risk tiers, model
routing) is built out.

Vocabulary alignment:

| This spec | SPEC.md §A KitchenRun | Notes |
|---|---|---|
| `RunReceipt` | `KitchenRun` + `RunSummary` artifact | Receipt is the user-facing rendering; KitchenRun is the full audit row. As the harness lands, RunReceipt becomes a view over KitchenRun, not a separate table. |
| `DiffRow` | `PlanDiff`, `GroceryDiff`, `PantryBeliefUpdate` (typed per-domain) | DiffRow is the simpler cross-surface shape that ships first. The typed per-domain artifacts come in later when verifiers need them. |
| `UndoPayload` (sum type, stored on `Events.Committed`) | `KitchenRun.undo_ref` | Same idea; this spec names the encoding (`:event_sourced` / `:snapshot` / `:composite` / `:irreversible`). |
| Belief state on PantryItem | `PantryBeliefsCapsule` framing (SPEC.md §4) | Same model. This spec lands the column; the capsule reads it. |
| Plan-slot locks | `PlanVerifier` "no locked slot was changed" check | This spec adds the events + projection; the verifier consumes them when it lands. |
| Tool classification (`:silent` / `:diff_row` / `:own_receipt`) | Run-kind declaration in `run_kinds.ex` | First pass at risk-tier-adjacent classification. Will fold into formal Tier 0–3 (SPEC.md §A.6.1) later. |

**Module layout.** Implementation lands under `lib/tore/harness/` (per
SPEC.md §Module Map), not a freestanding `lib/tore/receipts/` tree. Phase 1
scaffolds the harness directory with run_receipts as its first occupant:

```
lib/tore/harness/
  run_receipt.ex        # Ecto schema (this spec)
  run_receipt_diff.ex   # Ecto schema (this spec)
  undo_handle.ex        # sum-type encoding (this spec)
  run_receipts.ex       # context: record/1, get/1, undo/2 (this spec)
  # later, as the harness expands:
  kitchen_run.ex
  run_kinds.ex
  artifact.ex
  capsules/
  verifiers/
  resolvers.ex
  handles.ex
```

When the full `KitchenRun` schema lands, `RunReceipt` rows migrate to or
become a projection over `KitchenRun` rows. The migration cost is small
because the field overlap (id, household_id, intent, applied_at,
correlation_id, undo handle) is high.

**What this slice does NOT yet require:**

- Capsules (SPEC.md §A.4). The Capture Router still uses its current
  prompt-building path. Capsule extraction comes later.
- Verifiers (SPEC.md §A.5). Receipts ship without verifier gating; the
  reversibility-via-Undo property substitutes for verifier-blocked-commit
  in the interim. Verifiers land before Tier 3 (destructive) runs do.
- Resolver handles (SPEC.md §A.6.2). Tools still take strings/ids for now.
  Handle conversion is a follow-up phase.
- Risk tiers (SPEC.md §A.6.1). Tool classification (§7 below) is the
  proto-tier; formal Tier 0–3 mapping comes when verifiers do.
- Model routing (SPEC.md §A.8). Current single-model routing continues.

These deferred pieces are tracked in SPEC.md as the long-term harness;
nothing in this spec contradicts them.

---

## 1. Why this spec exists

UI_SPEC §16 says every agent-driven state change must produce a run receipt
that the user can Undo. The harness already models the lifecycle for this
(see Relationship section), but four concrete pieces are missing:

- **No undo payload on Committed events.** The `Reverted` event and state
  transition exist on the Run aggregate, but `Committed` doesn't carry the
  information needed to actually compensate the affected aggregates. There
  is no caller of `Commands.Revert` anywhere in the codebase.
- **No `belief` field on `PantryItem`.** Provenance and `last_seen_at`
  exist, but there is no field the UI can read to render
  `? probably at home` vs `+ confirmed`. Belief is a function of provenance
  + recency + agent corrections, not provenance alone.
- **No plan-slot lock events.** The agent has no way to know it must skip a
  user-pinned slot. Planning's event stream does not yet model
  `PlanSlotLocked` / `PlanSlotUnlocked`.
- **No receipt-rendering facade.** The Run aggregate's typed artifacts
  (`PlanDiff`, `PantryBeliefUpdate`, `CostEntry`, …) are the source of
  truth, but there is no module that projects them into the unified
  DiffRow shape UI_SPEC §16.4 specifies. Nothing in `lib/tore_web/` renders
  runs as receipts today.

Without these, the UI either lies (renders confidence it doesn't have),
loses the user's intent (overwrites locks), or makes Undo impossible.

## 2. The model

```
┌──────────────────────────────────────────────────────────────────┐
│ Capture turn                                                     │
│ user input → Router → tool calls                                 │
│                                                                  │
│ Each tool call that mutates state:                              │
│   1. Records the mutation as a RunReceipt entry                  │
│   2. Stores an undo handle (event ids / before-state snapshot)   │
│   3. Returns a structured DiffRow list to the Router             │
│                                                                  │
│ The Router emits ONE RunReceipt bubble per turn aggregating      │
│ all DiffRows from that turn.                                     │
└──────────────────────────────────────────────────────────────────┘
```

A turn produces at most one RunReceipt. Multiple tool calls within a turn
collapse into one receipt with grouped diff rows. Undo undoes the whole turn.

## 3. Artifacts

### 3.1 RunReceipt

A **derived view** over an `Applied` (or `Reverted`) `Tore.Harness.Run`
aggregate. Not a separate persisted table — the Run event stream is the
source of truth. The receipt is constructed at read time by projecting
the run's typed artifacts and state into the shape the UI consumes.

```
RunReceipt                       Derived from
  stream_id           string     Run.stream_id
  household_id        fk         Run state
  user_id             fk         Run state (the user who triggered the turn)
  trigger             enum       Run.started_by + Run.surface
  intent              string     Run.input (one-line summary)
  diff_rows           [DiffRow]  to_diff_rows(Run.artifacts)
  assumptions         [string]   collected from artifacts' rationale fields
  undo_payload        UndoPayload Applied.undo_payload (nil if not reversible)
  undo_expires_at     datetime   committed_at + TTL (see §4.4)
  applied_at          datetime   Applied.committed_at
  reverted_at         datetime?  Reverted.reverted_at (when state is Reverted)
```

A future spec may introduce a flat projection table for query performance
(e.g. a list-by-household index), but Phase 1 reads directly from the
event stream.

### 3.2 DiffRow

One line in a receipt. The four prefixes from UI_SPEC §16.4 (`+`, `-`, `~`, `?`)
map to the `op` field.

```
DiffRow
  op           enum   (:added, :removed, :changed, :assumed)
  surface      enum   (:plan, :shop, :pantry, :recipe, :prep, :cost)
  label        string (human-facing, household language)
  before       any?   (only for :changed)
  after        any?   (only for :added, :changed)
  reason       string? (one-line; renders as small text below row)
```

The DiffRow is what the UI renders. It does not carry ids or DB references;
that's what UndoPayload is for.

### 3.3 UndoPayload

What the system needs to reverse the turn. Stored on the
`Events.Committed` event (and therefore on `State.Applied`), so a
rehydrated run carries everything needed to compensate without re-reading
external aggregates.

```
UndoPayload (sum type)
  | :event_sourced   %{stream_id, stream_type, event_ids[]}  (Plan, Shop)
  | :snapshot        %{schema, row_id, before_attrs}  (Pantry, Recipes)
  | :composite       [UndoPayload]  (when a turn touches multiple)
  | :irreversible    %{reason}   (Undo button disabled, with explanation)
```

Irreversible actions still produce a receipt; the Undo button is just
greyed out and the row says why ("receipts committed cannot be undone here;
edit the cost entry from /receipts").

The payload is derived from the run's artifacts at commit time by
`UndoPayload.from_artifacts/2`. Each artifact kind knows how to describe
its own reversal (PlanDiff → event-sourced over `planning-<household>`;
PantryBeliefUpdate → snapshot of touched rows; CostEntry → irreversible).

## 4. Lifecycle

### 4.1 Producing a receipt

A receipt is a derived view; "producing" it means committing a Run with
enough information to project it. The Orchestrator already runs the
verify→commit cycle. Phase 1 adds: at commit time, derive an
`UndoPayload` from the run's typed artifacts and pass it into
`Events.Committed`. The Run aggregate stores it on `State.Applied`.

The Capture Router does not need to change in Phase 1 — its current
artifact-producing path is sufficient. Phase 2 wires Capture-driven
ad-hoc tool calls (today bypassing the harness) into Runs of their own
so that every state-changing tool path commits a Run.

### 4.2 Rendering

CaptureLive subscribes to the receipt for the active correlation_id. On
arrival, it renders a RunReceipt bubble (UI_SPEC §7.1) with:
- intent line
- grouped diff rows (by surface)
- assumptions block (if any)
- Undo button (disabled if `undo_payload` is `:irreversible`)

After Undo, the bubble re-renders with `reverted_at` set ("Reverted — Apply again?").

### 4.3 Undoing

`Tore.Harness.RunReceipts.revert(stream_id)`:
1. Loads the Run aggregate; checks state is `Applied` and
   `undo_expires_at` not passed.
2. Walks `Applied.undo_payload` and dispatches each piece to its
   compensator:
   - `:event_sourced` → append compensating events to the named stream.
   - `:snapshot` → restore `before_attrs` via the schema's update path.
   - `:composite` → recurse.
   - `:irreversible` → refuse with a structured error.
3. Dispatches `Commands.Revert` to the Run aggregate; the existing
   `Reverted` event records the transition.
4. (Phase 3) Optionally opens a small follow-up Run to record the undo
   itself in the activity log. Phase 1 just transitions the original.

### 4.4 Expiration

Undo handles have a default TTL (proposal: **24 hours** for low-blast-radius
mutations, **forever** for high-stakes ones like receipt commits — but those
are `:irreversible` here anyway). After expiry, the receipt persists for
audit but Undo is disabled.

## 5. Belief state on PantryItem

UI_SPEC §16.5 requires belief vocabulary. Add to `Tore.Pantry.PantryItem`:

```
belief          enum   (:confirmed, :probable, :uncertain, :missing)
last_seen_at    datetime
provenance      enum   (:manual, :receipt, :shelf_photo, :inferred)
```

`belief` is set by:
- `:manual` add → `:confirmed`
- receipt commit → `:probable` (we know it was bought, not that it's still there)
- shelf photo → `:confirmed`
- inference (agent guess based on similar recipes) → `:uncertain`
- agent `remove_from_pantry` → `:missing` (don't delete; mark missing)

The current schema is largely boolean. Migration plan in §8.

## 6. Lock on plan slots

UI_SPEC §16.6 requires user locks to outrank the agent. Add to the
plan-slot event stream:

```
PlanSlotLocked   { date, slot_key, locked_by_user_id, at }
PlanSlotUnlocked { date, slot_key, at }
```

State projection on Planning aggregate carries `locked_slots :: MapSet`.
Tools that mutate plan slots (`set_plan_slot`, `clear_plan_slot`, agent
suggestions) must check the projection:

- `set_plan_slot` with `force?: false` on a locked slot returns
  `{:error, :slot_locked}`. The agent surfaces this in the receipt:
  "Tore left Friday unchanged because it is locked by you."
- The user can explicitly unlock via UI.

`pin_plan_slot` (existing tool) becomes the agent-facing way to *request*
a lock; the actual lock event records `locked_by_user_id` of the active user.

## 7. Tool classification

> Applies to **Phase 2**, not Phase 1. Phase 1 works with the existing
> Orchestrator's artifact-producing runs and does not touch
> `Tore.Capture.Dispatch`.

Every agent tool gets classified for receipt production:

```
:silent      no receipt, no diff row
             (read-only tools: find_recipe, check_pantry, list_shopping_list)

:diff_row    produces a DiffRow that joins the turn's receipt
             (set_plan_slot, add_to_shopping_list, add_to_pantry, etc.)

:own_receipt produces its own RunReceipt, separate from the turn
             (receipt_commit, recipe_import — these are big enough that
             collapsing them into a chat turn's receipt would hide them)
```

Concrete classification of current `Tore.Capture.Dispatch` tools:

| Tool | Class | Undo |
|---|---|---|
| find_recipe | :silent | n/a |
| set_plan_slot | :diff_row | event-sourced |
| clear_plan_slot | :diff_row | event-sourced |
| suggest_meals_from_pantry | :silent | n/a (advisory) |
| add_to_shopping_list | :diff_row | event-sourced |
| check_off_shopping_item | :diff_row | event-sourced |
| list_shopping_list | :silent | n/a |
| generate_shopping_list_from_plan | :diff_row | event-sourced (batch) |
| add_to_pantry | :diff_row | snapshot |
| remove_from_pantry | :diff_row | snapshot |
| check_pantry | :silent | n/a |
| mark_recipe_cooked | :diff_row | snapshot |
| set_plan_servings | :diff_row | event-sourced |
| pin_plan_slot | :diff_row | event-sourced |
| skip_plan_meal | :diff_row | event-sourced |
| ingest_receipt | :own_receipt | :irreversible |
| update_pantry_from_shelf | :own_receipt | snapshot batch |

## 8. Phases

Implement in checkpoints, one commit per phase, each independently shippable.

### Phase 1 — Substrate for receipts and undo

**Existing harness state (as of 2026-06-27).** `lib/tore/harness/` already
exists with an event-sourced `Run` aggregate (Decider pattern, stream
type `"run"`), typed artifacts (`PlanDiff`, `PantryBeliefUpdate`,
`CostEntry`, `MemoryUpdate`, `RunSummary`), six capsules, four verifiers,
an Orchestrator, and projector machinery. The Run state machine already
models the lifecycle this spec needs (`Draft → Running → Applied →
Reverted` plus `NeedsUser`, `Failed`, `Discarded`). `pantry_items` already
has `provenance` (with values `manual | receipt | vision | belief |
grocery_checkoff`) and `last_seen_at`.

Phase 1 fills the four concrete gaps between what exists and what UI_SPEC
§16 needs:

1. **`belief` enum on `PantryItem`** — the column is missing. Provenance
   tells you *how* an item entered the inventory; belief tells you *how
   confident we are it is still there*. Migration adds the column with
   values `:confirmed | :probable | :uncertain | :missing`; backfill
   derives initial values from provenance:
   - `manual` → `:confirmed`
   - `receipt` → `:probable`
   - `vision` → `:confirmed`
   - `grocery_checkoff` → `:probable`
   - `belief` → `:uncertain`
2. **`UndoPayload` on `Events.Committed` and `Events.Reverted`** — the
   `Reverted` event exists but carries no information about what to
   compensate. Extend `Events.Committed{at, undo_payload}` where
   `undo_payload` is the sum-type encoding from §3.3. The
   `Run.Decider.evolve` for `Reverted` doesn't need the payload (state
   already carries it via the prior `Committed` event); the compensation
   caller reads it from the rehydrated `Applied` state.
3. **`Tore.Harness.RunReceipts` context** — a thin facade for the UI.
   Reads the Run aggregate and projects each `Applied` (or `Reverted`)
   run into a `RunReceipt` view-struct (intent line, grouped DiffRows,
   undo state, undo handle). Exposes `get/1`, `list_for_household/2`,
   `revert/1`. `revert/1` dispatches `Commands.Revert` to the Run
   aggregate AND walks the `undo_payload` to compensate the affected
   aggregates (Phase 3 wires the actual compensators; Phase 1 just
   defines the contract and a no-op compensator dispatcher).
4. **`DiffRow` derivation from existing artifacts** — `RunReceipts`
   derives the cross-surface DiffRow list from the typed artifacts the
   run already produces (`PlanDiff` → plan-surface DiffRows;
   `PantryBeliefUpdate` → pantry-surface DiffRows; `CostEntry` →
   cost-surface DiffRows). DiffRow is a render-time shape, not stored;
   the canonical record stays in the typed artifact on the event stream.

**What this phase explicitly does NOT do:**

- No new `run_receipts` table. Receipts derive from the existing Run
  event stream; persisting them separately would duplicate state.
- No new `Tore.Harness.RunReceipt` Ecto schema for the same reason.
- No `Tore.Harness.RunReceiptDiff` schema — DiffRow stays in-memory.
- No plan-slot lock events yet. Phase 5 adds them; the spec's earlier
  promise to land them in Phase 1 is dropped because the Orchestrator
  doesn't yet consume them and emitting events with no reader is dead
  code.
- No tool refactor. `Capture.Dispatch` continues to return its current
  shapes; Phase 2 changes it.

**Phase 1 deliverables, concretely:**

- Migration: add `belief` column to `pantry_items` + backfill from
  provenance.
- `Tore.Pantry.PantryItem` schema update (field + validation).
- `Tore.Harness.UndoPayload` module — sum-type encoding
  (`:event_sourced` / `:snapshot` / `:composite` / `:irreversible`),
  with `from_artifacts/2` to derive the payload from a run's typed
  artifacts at commit time.
- Extend `Tore.Harness.Run.Events.Committed` with `undo_payload`; extend
  `Run.State.Applied` to carry it; update `Decider.decide(Commit)` to
  accept and propagate.
- `Tore.Harness.RunReceipts` module — `get/1`, `list_for_household/2`,
  `revert/1`, `to_diff_rows/1` (artifact → DiffRow projection).
- Tests for: belief backfill, UndoPayload encoding round-trip,
  RunReceipts.to_diff_rows projection, Decider Commit propagates
  undo_payload to Applied state.

### Phase 2 — Capture-driven mutations commit Runs

- Today, `Tore.Capture.Dispatch` tools mutate plan/shop/pantry directly
  outside any Run. Refactor each state-changing dispatch to open a Run,
  produce its typed artifact, and commit — so every Capture-driven
  mutation has a stream and an `Applied` state with an `UndoPayload`.
- Multi-tool turns either (a) open one Run per tool call (per-step
  receipts) or (b) open a parent Run that owns child commits as
  composite artifacts. Decide when implementing — leaning (a).
- CaptureLive renders Runs as receipt bubbles (Undo button still no-op
  until Phase 3 lands).
- Existing `shop_link` bubble becomes the rendering of a shop-surface
  DiffRow group; same component, fed by the receipt.

### Phase 3 — Undo wired

- `Tore.Harness.RunReceipts.revert/1` actually compensates
  event-sourced and snapshot payloads (Phase 1 defines the contract;
  Phase 3 implements the per-aggregate compensators).
- CaptureLive Undo button calls it and shows the "Reverted" state.
- Toast on Plan/Shop when an Undo affecting that surface lands (PubSub).

### Phase 4 — Belief state surfaces in the UI

- (Schema change lands in Phase 1.) Phase 4 wires reads:
- `Pantry.upsert_belief/1` sets `belief` based on provenance + recency.
- Shop list rendering checks pantry belief for items in
  `:probable`/`:confirmed` state and renders the `?` prefix with copy.
- Pantry list groups by belief, not just category.

### Phase 5 — Locks

- New plan-slot events and projection.
- Tools check `locked_slots` projection; emit `:slot_locked` diff row
  ("Tore left Friday unchanged — locked by you") when refusing.
- UI: lock toggle on plan slot card (Phase 5 of UI rebuild, separate spec).

### Phase 6 — Own-receipt flows + irreversible labelling

- `:irreversible` receipts for receipt commits with explanation copy.
- Recipe import opens its own Run with a snapshot UndoPayload.

## 9. Non-goals

- **No Needs-Review inbox** in this spec. The agent-acts-immediately model
  makes it unnecessary for the common path. Defer until evidence shows
  certain mutations need a stage step.
- **No proposal/apply approval flow.** Same reason.
- **No multi-user concurrent-edit conflict resolution** beyond what
  event-sourced contexts already give us. If two users mutate the same
  slot in the same second, last write wins; the loser's RunReceipt still
  shows what they did and Undo restores their version.
- **No cross-household receipts.** Receipts are household-scoped.

## 10. Open questions

- **Q1.** Should `:irreversible` tools (receipt_commit) get a confirmation
  step in Capture before applying, given Undo can't help? Default answer:
  no — they already have their own review card. Keep the doctrine pure.
- **Q2.** Undo TTL — 24h is a guess. Revisit after Phase 3 ships and we
  see how often Undo gets used past the same-session window.
- **Q3.** Should run receipts surface in Today / Plan / Shop as small
  "Tore changed this 5 min ago — Undo" footers, not just in Capture?
  Probably yes (UI_SPEC §16.3.2 implies it). Decide when building the
  UI for those surfaces.

## 11. Decision log

- **2026-06-24:** Chose agent-acts-immediately over proposal-approval.
  Trust through visibility + reversibility, not friction. Doctrine
  appended to UI_SPEC §16 reflects this.
- **2026-06-24:** Named the artifact `RunReceipt` (matches UI_SPEC §7.1
  vocabulary) instead of `Proposal`. The earlier draft used `Proposal`
  but that implied an approval gate we're not building.
- **2026-06-27:** Reconciled with SPEC.md §Agent Harness. This spec is a
  vertical slice of the KitchenRun harness, not a parallel track.
  Phase 1 modules land under `lib/tore/harness/` (per SPEC.md §Module
  Map), so subsequent harness phases (capsules, verifiers, resolvers)
  extend the same directory rather than building beside it. Capsules,
  verifiers, resolver handles, formal risk tiers, and model routing
  are explicitly deferred to later phases — listed in the Relationship
  section.
- **2026-06-27 (#2):** Reconciled with the existing harness implementation.
  Code-reality check found that `lib/tore/harness/` is already built:
  event-sourced `Run` aggregate with `Draft → Running → Applied →
  Reverted` lifecycle, typed artifacts, capsules, verifiers, Orchestrator,
  and projector. Also: `pantry_items` already has `provenance` and
  `last_seen_at`. Phase 1 rewritten to (a) drop the proposed
  `run_receipts` table — receipts derive from the existing event stream;
  (b) drop standalone `RunReceipt` / `RunReceiptDiff` Ecto schemas; (c)
  rename `UndoHandle` to `UndoPayload` and store it on `Events.Committed`
  rather than as a separate handle; (d) move belief-state schema work
  from Phase 4 into Phase 1 (only Phase 4 wires consumers); (e) move
  plan-slot lock events from Phase 1 to Phase 5 where the consumer
  lands. Net effect: Phase 1 is smaller and additive to existing code.
