# Real PlanDiff from tool outcomes — design

**Date:** 2026-06-05
**Status:** approved (pending spec review)
**Sub-spec of:** harness (see `2026-06-02-harness-foundation-design.md`)

## Problem

`Tore.Harness.Orchestrator.build_plan_diff/1` emits a hardcoded placeholder
`PlanDiff` on every successful run:

```elixir
%PlanDiff{
  plan_stream_id: ctx.plan_stream_id,
  week_start: ctx.week_start,
  events: [%{slot_key: "run", event_type: "MealSkipped", payload: %{},
             rationale: ["planner command applied"]}]
}
```

So the run receipt always reads "1 skipped" regardless of what the planner
actually did. This sub-spec replaces the placeholder with a real diff
reconstructed from the planner's executed tool calls.

## Goal

After a planner command runs, the `PlanDiff` artifact (and therefore the
`RunSummary` and the receipt) reflects exactly the plan changes that
successfully persisted, each carrying the LLM's stated rationale.

## Non-goals

- No change to the event-sourcing model, Decider, Projector, or persistence.
- No change to how the receipt component (`ReceiptLive`) is wired — it already
  renders `RunSummary.text_fallback`.
- No new artifact kinds; `PlanDiff` and `RunSummary` are extended in place.

## Data flow

`PlannerAgent.run/4` already records a `tool_trace`:

- a `:tool_calls` entry per round trip with
  `payload: %{calls: <JSON string of [%{id, name, args}]>}`
- a `:tool_result` entry per executed call with
  `payload: %{tool_call_id, name, result}`

At close time, `Orchestrator.close/4` (the `{:message, _}` and `{:capped, _}`
branches) calls a new pure module **`Tore.Harness.PlanDiffBuilder`** with
`loop.tool_trace` and `ctx`, in place of `build_plan_diff/1`. The builder:

1. Decodes every `:tool_calls` entry's `calls` JSON into `{id, name, args}`
   tuples and indexes them by `id`.
2. Walks `:tool_result` entries. For each, joins to its call args by
   `tool_call_id`.
3. Keeps only **successful action** results — drops:
   - read tools and `ask_user` (by tool name; only the six action tools map),
   - results that are errors (`%{error: _}`), `action_cap_reached`, or
     otherwise not a success map.
4. Maps each surviving `(name, args, result)` to one `PlanDiff` event_entry.
5. Returns `%PlanDiff{plan_stream_id: ctx.plan_stream_id,
   week_start: ctx.week_start, events: events}` (events in trace order).

If no successful actions occurred (planner only asked a question, or every
action failed), `events: []`. `RunSummary.from_artifacts/2` already produces an
empty-count summary whose `text_fallback` is the "Nothing to apply" message, so
the receipt degrades gracefully with no special-casing.

The Orchestrator's command sequence at close is unchanged:
`AddArtifact(PlanDiff)` → `AddArtifact(RunSummary)` → `Commit`. Only PlanDiff
*construction* changes; `build_plan_diff/1` is deleted.

## Tool → event mapping

Each successful action call becomes exactly one `event_entry`. `rationale`
comes from a new **required** `rationale` string arg on each action tool
(`[text]`; if the LLM omits it despite being required, the builder falls back
to `[]` rather than crashing).

| Tool | `event_type` | `slot_key` | `payload` |
|------|-------------|-----------|-----------|
| `assign_recipe` | `RecipeAssigned` | `args["slot_key"]` | `%{"recipe_id" => id, "servings" => n, "label" => title}` |
| `skip_meal` | `MealSkipped` | `args["slot_key"]` | `%{}` |
| `mark_leftover` | `LeftoverMarked` | `args["slot_key"]` | `%{}` |
| `remove_recipe` | `RecipeRemoved` | `args["slot_key"]` | `%{}` |
| `swap_recipe` | `RecipeSwapped` | `args["to_slot_key"]` | `%{"from_slot_key" => f, "to_slot_key" => t, "recipe_id" => id, "label" => title}` |
| `set_servings` | `ServingsChanged` | `args["slot_key"]` | `%{"servings" => n}` |

Payload keys are strings (they round-trip through JSON; PlanDiff's
`event_entry` payload is already an opaque `map()` stored verbatim).

### Recipe label

To let the receipt name a recipe ("added Roast chicken"), the two
recipe-placing tools return the title in their success result:

- `assign_recipe`: after `PlanningHandler.assign_recipe/4` succeeds, look up the
  recipe title by `args["recipe_id"]` and return `{:ok, %{ok: true, label: title}}`.
- `swap_recipe`: see "Atomic swap fix" below — after the true swap succeeds,
  return `{:ok, %{ok: true, label: to_title, recipe_id: to_rid}}` where the
  label/id describe the recipe that now sits in `to_slot_key`.

The builder reads `result["label"]` / `result[:label]` (tolerant of atom/string
keys) into the payload. If absent, `label: nil` and the receipt falls back to
count wording.

## PlanDiff artifact changes

`lib/tore/harness/artifact/plan_diff.ex`:

- `rollup_change` type gains `:servings`. Full set:
  `:added | :swapped | :skipped | :leftover | :removed | :servings`.
- `rollup_for/2` replaces its `cond` with a direct event_type → change mapping:
  - `RecipeSwapped` → `:swapped`
  - `RecipeAssigned` → `:added`
  - `MealSkipped` → `:skipped`
  - `LeftoverMarked` → `:leftover`
  - `RecipeRemoved` → `:removed`
  - `ServingsChanged` → `:servings`
  - fallback `true -> :added` (safety net for an unknown type)
- The old derived branch
  (`"RecipeRemoved" in types and "RecipeAssigned" in types -> :swapped`) is
  **removed** — swap is now atomic, so no tool emits that pair.

`summarise/1`, `summary/1`, `to_json/1`, `from_json/1`,
`is_rationale_complete/1` are otherwise unchanged. (With `rationale` now
required on every action tool, `is_rationale_complete/1` returns `true` for a
conforming run; it stays meaningful as a guard against a model that omits one.)

## RunSummary wording

`lib/tore/harness/artifact/run_summary.ex` — `text_from_counts/1` (the count →
prose helper, currently `"#{n} #{change}"`) gets human wording per change type:

- `:added` → "added"
- `:swapped` → "swapped"
- `:skipped` → "skipped"
- `:leftover` → "leftovers"
- `:removed` → "removed"
- `:servings` → "servings adjusted"

Example: counts `%{added: 1, servings: 1}` → "1 added, 1 servings adjusted".
The existing empty-count fallbacks ("Question raised" / "Failed" / "Nothing to
apply") are unchanged.

> Note: `PlanDiff.summary/1` builds its own `text_fallback` via
> `text_from_counts` too. Keep PlanDiff's local helper in sync with the same
> wording, OR (preferred) have both read a single shared label function. Since
> the receipt renders the **RunSummary** text_fallback (not PlanDiff's), the
> RunSummary wording is the load-bearing one; PlanDiff's is only used if a
> PlanDiff is summarised directly. Update both for consistency; do not extract a
> shared module unless it falls out naturally (avoid a single-use abstraction).

## Planner tool changes

`lib/tore/llm/planner_tools.ex` — add a `rationale` property to each of the six
action tools' `parameters.properties` AND to each tool's `required` list:

```elixir
rationale: %{type: "string",
  description: "One short clause explaining why you are making this change."}
```

`rationale` is **required** so the LLM must justify every action. The `run`
funcs do not consume `rationale` (it is not a planning arg); the builder reads
it from the recorded call args, not from the result. The builder still tolerates
a missing/blank rationale (→ `[]`) defensively, so a non-conforming model
response degrades gracefully instead of crashing.

Prompt guidance: add one line to `Orchestrator.agent_preamble/0` instructing the
agent to pass a brief `rationale` with each action call.

### Atomic swap fix (domain bug found during smoke)

The current `swap_recipe` is a **move**, not a swap: it copies `from_slot`'s
recipe into `to_slot` (overwriting it) and clears `from_slot`. When the LLM
tried a real swap (fri↔sun) by chaining two moves, the first move overwrote
Sunday before the second could read it — destroying Sunday's recipe and leaving
both slots with Friday's. A true swap must be atomic.

Rewrite `swap_recipe`'s `run` to perform a real cross-assign in one batch,
following the `assign_with_leftovers/5` pattern (load once, decide+evolve a
sequence, append all events in one `EventStore.append` + one broadcast). To keep
the harness pure-mapping clean, add a `PlanningHandler.swap_slots/3`:

```elixir
@spec swap_slots(plan_id, slot_a, slot_b) :: {:ok, [event]} | {:error, term}
def swap_slots(plan_id, slot_a, slot_b)
```

Semantics (read both slots' `{recipe_id, servings}` first, then cross-assign):
- both slots have recipes → A's recipe→B, B's recipe→A (servings travel with
  the recipe).
- one slot empty → move the recipe to the empty slot, clear the source
  (degenerate swap; no data loss).
- both empty → `{:error, :nothing_to_swap}`.

`swap_recipe`'s tool `run` calls `swap_slots/3`, then resolves the title of the
recipe now in `to_slot_key` for the `label`. The tool's args remain
`from_slot_key` / `to_slot_key` (+ optional `rationale`).

This makes the tool, the atomic `RecipeSwapped` PlanDiff event, and the receipt
all describe the same real operation.

## New module

`lib/tore/harness/plan_diff_builder.ex` — pure, no DB/IO.

```elixir
@spec build([trace_entry()], ctx :: map()) :: Tore.Harness.Artifact.PlanDiff.t()
def build(tool_trace, ctx)
```

Internals (all private, pure):

- `index_calls/1` — fold `:tool_calls` entries, `Jason.decode!` each `calls`
  string, return `%{call_id => %{name, args}}`.
- `events_from_results/2` — walk `:tool_result` entries, join args by
  `tool_call_id`, filter to successful actions, map via `event_for/3`.
- `event_for(name, args, result)` — the mapping table above; returns an
  `event_entry` or `nil` (nil = not an action / not successful, filtered out).
- `success?/1` — `true` for a result map with no `:error`/`"error"` key. (The
  cap and validation failures already surface as `%{error: "action_cap_reached"}`
  / `%{error: ...}` in the trace, so this single check covers them.)
- `rationale_of/1` — `args["rationale"]` → `[text]` or `[]`.

## Testing

**`test/tore/harness/plan_diff_builder_test.exs`** (pure, fast):

- each action tool → its event_type, slot_key, payload (incl. label for
  assign/swap, servings for set_servings).
- rationale arg flows into `rationale: [text]`; absent → `[]`.
- failed result (`%{error: _}`) → excluded.
- `action_cap_reached` result → excluded.
- read tool / `ask_user` result → excluded.
- empty trace / no successful actions → `events: []`.
- multiple actions in one run → events in trace order.
- args/result joined correctly by `tool_call_id` across multiple round trips.

**`test/tore/harness/artifact/plan_diff_test.exs`** (extend):

- `RecipeSwapped` → `:swapped`; `ServingsChanged` → `:servings` in `summarise/1`.
- old derived-pair branch no longer needed (a lone RecipeRemoved → `:removed`,
  a lone RecipeAssigned → `:added`).

**`test/tore/harness/artifact/run_summary_test.exs`** (extend):

- `text_from_counts` wording for each change type incl. `:servings`.

**`test/tore/harness/orchestrator_test.exs`** (extend):

- a run whose mocked tool loop produces a successful `skip_meal` yields a
  PlanDiff with one `MealSkipped` event (not the placeholder), and the receipt
  text reflects "1 skipped".

**`test/tore/llm/planner_tools_test.exs`** (extend):

- `assign_recipe`/`swap_recipe` success results include `label` (recipe title).
- `swap_recipe` performs a TRUE swap: given fri=RecipeA, sun=RecipeB, after one
  `swap_recipe(fri↔sun)` the plan has fri=RecipeB and sun=RecipeA, with neither
  recipe lost (the regression for the smoke bug).

**`test/tore/handlers/planning_handler_test.exs`** (extend or add):

- `swap_slots/3`: both-full swaps recipe+servings; one-empty moves + clears;
  both-empty returns `{:error, :nothing_to_swap}`.

## Success criteria

1. `build_plan_diff/1` is deleted; Orchestrator builds the diff via
   `PlanDiffBuilder.build/2`.
2. A real planner command (`skip sat dinner`) produces a PlanDiff whose single
   event is `MealSkipped` on `sat_dinner`, and the receipt reads "1 skipped"
   — verified by the orchestrator test, and confirmable by manual smoke.
3. A multi-action command surfaces one event per successful action, in order.
4. Failed / capped / read-tool calls never appear in the diff.
5. Each event carries the LLM's rationale when supplied.
6. `swap_recipe` is a true atomic swap: swapping two occupied slots exchanges
   their recipes with no data loss (regression for the smoke bug); it emits one
   `RecipeSwapped` event and the receipt reads "1 swapped".
7. Full suite green (no new failures vs the harness baseline);
   `mix compile --warnings-as-errors` clean.
