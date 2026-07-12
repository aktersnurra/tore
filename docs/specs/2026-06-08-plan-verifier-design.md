# A.5 Verifiers — Pure Planner Loop + PlanVerifier Design

**Date:** 2026-06-08
**Spec section:** SPEC.md §A.5 (Verifiers run after every state-changing run)
**Scope:** Make the planner loop **verify-then-mutate** (Part 1), then add the
first verifier — `PlanVerifier` — into the resulting gate (Part 2), for the one
shipped run kind (`:planner_command_run`).

## Goal

Close the load-bearing harness gap **correctly**. SPEC §A.5 mandates that every
state-changing `KitchenRun` is checked by a deterministic verifier *before* its
changes commit, and that a verifier failure is **atomic — nothing commits**.

Today neither half holds:

1. The planner's action tools **mutate the plan aggregate eagerly** during the
   loop (`PlanningHandler.skip_meal/assign_recipe/...` append to the plan stream
   immediately). By the time the run reaches `:verifying`, the plan is already
   changed.
2. `Orchestrator.close/4` enters `:verifying` and commits the `PlanDiff` with
   **no verifier**.

So even if we added a verifier, "nothing commits" would already be false — the
plan slots would have moved. The correct fix is **verify-then-mutate**: the
action tools become pure (they propose changes against an in-memory working copy
of the plan, never persisting), and the Orchestrator persists the accumulated
plan changes **only after** the verifier passes. Failure means the plan stream
was never touched — true atomicity, no compensation.

This spec delivers that in two parts within one plan:

- **Part 1 — Pure planner loop / verify-then-mutate seam.** The loop carries a
  working `Planning.State`; action tools call the pure `Planning.Decider`
  against it (preserving the model's mid-loop error feedback) and return the
  evolved state plus the events they produced; the Orchestrator applies the
  accumulated events to the plan stream once, after the loop. At the end of
  Part 1 the planner is fully functional and verify-then-mutate, with the apply
  step **always** running (no gate yet).
- **Part 2 — PlanVerifier + repair surfacing.** A pure `verify/2` slots into the
  Part-1 seam: pass → apply + commit; fail → `RecordFailure` (plan never
  touched), `State.Failed` with a structured code and a manual-edit
  `repair_action`, surfaced as a localized repair state with planner slot-focus.

## Non-goals

- No other verifiers (`GroceryVerifier`, `PrepVerifier`, …). Only `PlanVerifier`.
- No generic `Verifier` behaviour / registry. One concrete module. Extract a
  contract when the second verifier lands, informed by two real cases.
- No model retry on verifier failure (SPEC §A.5 hard rule).
- No change to read tools (`search_recipes`, `pantry_snapshot`, `active_deals`)
  or the terminal `ask_user`.

---

# Part 1 — Pure planner loop / verify-then-mutate seam

## The purity principle

The plan aggregate is **already** a pure Decider:

- `Tore.Planning.Decider.decide(command, state) :: {:ok, [event]} | {:error, reason}`
- `Tore.Planning.Decider.evolve(state, event) :: state`

Neither touches the database. The only impurity is `Tore.Handlers.PlanningHandler`,
which wraps `decide` with `EventStore.append` + PubSub broadcast. The clean
change is therefore **not** to invent a new in-memory mechanism — it is to stop
calling the impure wrapper inside the loop and call the pure Decider directly
against a working copy of the state. The same validation logic that guards
`:slot_empty` / `:not_pinned` runs in the loop, just against an in-memory state
instead of a freshly-loaded-and-persisted one. No rule is duplicated.

## Loop data flow (target)

```
Orchestrator loads working_plan = PlanningHandler.load_plan(ctx.plan_stream_id)  (once)
  passes it into PlannerAgent.run/4 via ctx (ctx.working_plan)

PlannerAgent loop state carries:
  working_plan :: Planning.State
  plan_events  :: [Planning.Events.t()]   # accumulated, in call order

each ACTION tool call:
  Decider.decide(cmd_from_args, working_plan)
    {:ok, events} → working_plan' = Enum.reduce(events, working_plan, &Decider.evolve/2)
                    plan_events'  = plan_events ++ events
                    tool returns {:ok, result_map}      # result/label computed from events + working_plan'
    {:error, r}   → tool returns {:error, r}            # fed back to the model, exactly as today
                    working_plan and plan_events unchanged

loop ends → loop_outcome now also carries: working_plan (final), plan_events (accumulated)

Orchestrator (Part 1, no gate yet):
  EventStore.append(ctx.plan_stream_id, plan_events)    # once, in order — the single persistence point
  AddArtifact(PlanDiff) → AddArtifact(RunSummary) → Commit
```

## How tools change

Action tools currently look like (eager, impure):

```elixir
run: fn args, ctx ->
  PlanningHandler.skip_meal(ctx.plan_id, args["slot_key"]) |> wrap_ok()
end
```

They become pure proposals against the working plan. Because tool functions need
to **read and update** the working plan, the tool-run contract changes from
`(args, ctx) -> {:ok, result} | {:error, reason}` to one that also threads the
plan. We thread it through `ctx` is **not** viable (ctx is immutable across
calls), so the working plan lives in the **agent loop state** and action tools
receive it and return the next one:

```elixir
# new action-tool contract
run: fn args, ctx, working_plan ->
  cmd = %Commands.SkipMeal{slot_key: args["slot_key"]}
  case Decider.decide(cmd, working_plan) do
    {:ok, events} ->
      next = Enum.reduce(events, working_plan, fn ev, acc -> Decider.evolve(acc, ev) end)
      {:ok, %{ok: true}, events, next}
    {:error, reason} ->
      {:error, reason}
  end
end
```

Read tools keep the old 2-arity contract and ignore the plan. To avoid two
contracts, **all** tools adopt the 3-arity `run: fn args, ctx, working_plan ->`
form; read tools simply return `{:ok, result, [], working_plan}` (no events, plan
unchanged). `ask_user` likewise returns `{:ok, result, [], working_plan}`.

### Tool-by-tool command mapping

| Tool | Command built from args | Result map (unchanged shape) |
|---|---|---|
| `assign_recipe` | `%Commands.AssignRecipe{slot_key, recipe_id, servings}` | `%{ok: true, label: recipe_title(recipe_id)}` |
| `swap_recipe` | *(no single command — see note)* | `%{ok: true, label: recipe_title(to_recipe_id), recipe_id: to_recipe_id}` — `to_recipe_id` read from the **evolved working plan**, not the DB |
| `skip_meal` | `%Commands.SkipMeal{slot_key}` | `%{ok: true}` |
| `mark_leftover` | `%Commands.MarkLeftover{slot_key}` | `%{ok: true}` |
| `set_servings` | `%Commands.SetServings{slot_key, servings}` | `%{ok: true}` |
| `remove_recipe` | `%Commands.RemoveRecipe{slot_key}` | `%{ok: true}` |

*`swap_recipe`: `PlanningHandler.swap_slots/3` is **already** built from a pure
core — it reads the two slots, builds a list of `AssignRecipe`/`RemoveRecipe`
commands via the private `swap_commands/4`, reduces them through `Decider.decide`
+ `evolve`, then appends once. No new `SwapSlots` command is needed. Expose that
pure core (the `swap_commands/4` cross-assign + the decide/evolve reduce) as a
pure helper — e.g. `PlanningHandler.swap_events(working_plan, from, to) ::
{:ok, [event], next_state} | {:error, :nothing_to_swap}` — and have both the
tool and the existing impure `swap_slots/3` call it (the latter wraps it with
the append + broadcast). This is a refactor-extract, not a new abstraction.
`recipe_title/1` stays a DB read (recipe titles are not plan state); it already
rescues `Ecto.NoResultsError -> nil`.

## PlannerAgent loop changes

`Tore.LLM.PlannerAgent`:

- `run/4`: read `ctx.working_plan` into the loop state; initialize
  `plan_events: []`.
- `handle_tool` / `run_and_record`: call `tool.run.(call.args, state.ctx,
  state.working_plan)`. On `{:ok, result, events, next_plan}`: append the tool
  result to the trace/messages (as today), set `state.working_plan = next_plan`,
  `state.plan_events = state.plan_events ++ events`. On `{:error, reason}`:
  append the error result (as today); plan and events unchanged.
- `finish/2`: include `working_plan` and `plan_events` in the `loop_outcome` map.
- `@type loop_outcome` gains `working_plan: Planning.State.t()` and
  `plan_events: [Planning.Events.t()]`.

The loop stays pure: it performs **no** DB writes. It does read (via the recipe
title lookup inside tools), which is acceptable — `PlannerAgent`'s moduledoc
"no DB writes" is preserved; reads were already happening (the prior eager tools
both read and wrote; now they only read).

## Orchestrator changes (Part 1)

`Orchestrator.dispatch(:planner_command_run, ctx)`:

- Before `PlannerAgent.run/4`, load the working plan and put it in the agent ctx:
  `working_plan = PlanningHandler.load_plan(ctx.plan_stream_id)` →
  `agent_ctx(ctx, sid) |> Map.put(:working_plan, working_plan)`.
- `close/4` (`:message` and `:capped` clauses): after building the `PlanDiff`,
  **persist the accumulated plan events once**:
  `:ok = PlanningHandler.apply_events(ctx.plan_stream_id, loop.plan_events)`
  then `AddArtifact(diff) → AddArtifact(summary) → Commit` (as today).
  `apply_events/2` is a thin new `PlanningHandler` function:
  `EventStore.append(plan_id, events)` + the existing PubSub broadcast, with
  `events == []` short-circuiting to `:ok`.
- `{:question, q}` clause unchanged — a `:needs_user` run applies nothing (the
  loop was interrupted; no commit, no plan write). This matches the eager
  behaviour today only insofar as a question ends the loop; under purity it is
  strictly cleaner (nothing was written mid-loop).

At the end of Part 1: the planner is verify-then-mutate, the apply step always
runs, the plan stream is written exactly once per run, and all existing
orchestrator/planner tests pass (adjusted for the new contract).

## Part 1 testing

- **PlannerTools unit tests** (pure): for each action tool, given a working
  `Planning.State`, calling `run.(args, ctx, state)` returns the right events +
  evolved state, and returns `{:error, reason}` (e.g. `:slot_empty`) without
  mutating. No DB writes occur (assert the plan stream is untouched).
- **PlannerAgent loop test:** a two-step Mock loop (action call then message)
  returns a `loop_outcome` whose `plan_events` reflect the action and whose
  `working_plan` is evolved accordingly. (That the loop performs no plan-stream
  write mid-loop is proven by the Orchestrator integration test below, which
  checks the plan stream stays empty until apply.)
- **Orchestrator integration:** the existing "builds a real PlanDiff from
  skip_meal" test still passes, AND a new assertion: after dispatch, the plan
  stream contains exactly the events the loop accumulated (applied once), and a
  run that ends in `:message` leaves the plan stream written. A `{:error, …}`
  step (LLM error) leaves the plan stream **empty** (nothing applied).
- Existing orchestrator tests updated for the new agent ctx / contract.

---

# Part 2 — PlanVerifier + repair surfacing

With the Part-1 seam in place, the gate is a branch inside `close/4` **before**
the apply step.

## The gate

```
build PlanDiff
  → PlanVerifier.verify(plan_diff, verify_ctx)
      :ok                    → apply_events → AddArtifact(diff) → AddArtifact(summary) → Commit
      {:fail, code, repair}  → RecordFailure{code, user_message: nil, repair_action: repair}
                               (apply_events NOT called — plan stream never written)
```

### Correctness properties

- **Atomic, truly nothing commits.** On `{:fail, …}` the code never calls
  `apply_events` (no plan write) and never `AddArtifact`/`Commit` (no run
  artifacts). The run transitions straight to `State.Failed`. Because Part 1
  made the tools pure, the plan slots are genuinely unchanged — the load-bearing
  §A.5 rule now holds literally.
- **Verifier failure is a successful dispatch of a failed run.** `close/4`'s
  fail branch returns `{:ok, failed_state}`, not `{:error, {:step_failed, _}}`.
  The typed `dispatch_error` stays reserved for infrastructure failures.
- **The error boundary still wraps everything.** `verify/2` runs inside the
  existing `with`/`try` chain; a *raised* verifier bug → `{:run_crashed, _}` →
  `record_failure/2` (`:internal_error`). A *clean* verifier failure is a
  deliberate `RecordFailure` with the verifier's structured code.
- **No model retry.** Record `Failed` and stop.

## PlanVerifier

New module `Tore.Harness.Verifier.PlanVerifier`. Pure-ish: deterministic reads
only — no writes, no model calls (a recipe read is side-effect-free in the §A.5
sense: no mutation, no LLM, cheap, deterministic).

```elixir
@type repair_action :: {:edit_plan, [String.t()]}
@type fail_code ::
        :slot_pinned | :servings_missing | :skip_not_explicit
        | :leftover_no_source | :dietary_violation

@spec verify(PlanDiff.t(), verify_ctx) :: :ok | {:fail, fail_code, repair_action}
```

### Verify context

The Orchestrator assembles `verify_ctx` from data it already has after the loop:

```elixir
%{
  plan_state: loop.working_plan,                  # the final post-loop in-memory plan (pre-apply)
  preferences: Tore.Household.get_preferences()   # dietary_restrictions ++ allergies ++ dislikes
}
```

Using `loop.working_plan` is exactly right: it is the post-diff plan **as it
would be after applying**, available without having written anything. `pins` are
on it already.

### Checks (run in fixed order; first failure wins)

| # | Check | Data source | Fail code |
|---|---|---|---|
| 1 | No pinned slot was changed | `plan_state.pins` keys ∩ diff slot_keys | `:slot_pinned` |
| 2 | Every assigned recipe has positive integer servings | diff `RecipeAssigned`/`ServingsChanged` payloads | `:servings_missing` |
| 3 | Skipped slots are explicit — every `MealSkipped` targets a slot present in the plan | diff `MealSkipped` vs. `plan_state.slots` | `:skip_not_explicit` |
| 4 | Leftover points to a valid source meal earlier in the week — every `LeftoverMarked` slot has an assigned (non-skipped, non-leftover) source ordered before it | diff `LeftoverMarked` + slot ordering over `plan_state.slots` | `:leftover_no_source` |
| 5 | No banned/allergen/disliked ingredient in any assigned recipe — load each `recipe_id`, intersect ingredient names against `dietary_restrictions ++ allergies ++ dislikes` | diff `recipe_id`s → `Recipes.get!/1` (rescue `Ecto.NoResultsError`) | `:dietary_violation` |

The verifier returns codes + slot_keys only — no user-facing copy. `nil`/empty
inputs pass. Each failure returns `{:fail, code, {:edit_plan, offending_slots}}`.

**Slot ordering (check 4):** slot keys are `"<day>_<meal>"`. Order by weekday
`mon<tue<wed<thu<fri<sat<sun`, meal as tiebreaker. A leftover slot is valid iff
some earlier slot has a `recipe_id` and is neither `skipped` nor `leftover`,
read from the post-loop `plan_state` (so a recipe assigned earlier in the same
run counts).

### Deferred check (written reason)

SPEC §A.5 lists a sixth check: *"no recipe twice within the household's
configured repeat window."* **Deliberately not implemented here.** It needs a
`repeat_window` value that (a) is not in `Household.Preferences`, (b) is not
derivable (`planning_days` is plan length, not a repeat tolerance), and (c) is a
genuine product decision (same week? N days? across weeks?). Implementing it
against a fabricated constant would be *less* correct than not checking — it
would silently block real plans on a number nobody chose. The honest path is a
small follow-up that adds a `repeat_window` preference (migration + changeset +
default + settings affordance) then adds check 6. Recorded as deferred, not
dropped.

## Failure surfacing & the repair affordance

### 1. `repair_action` round-trip

`State.Failed` already carries `failure_code`, `failure_user_message`, and
`failure_repair_action` (via `FailureRecorded` → `to_failed/2`). Today
`failure_repair_action` round-trips as a bare atom via `Run.rehydrate/1`'s
`safe_atom/1`. It becomes `{:edit_plan, [slot_key]}`.

A tuple **cannot** be `Jason`-encoded, so a write-side encoder is **required**
(not optional), mirroring how `Run.prepare/1` already special-cases
`ArtifactAdded`:

- **Write side (`Run.prepare/1`):** add a `%Events.FailureRecorded{}` clause that
  serializes `repair_action: {:edit_plan, slots}` →
  `%{"action" => "edit_plan", "slots" => slots}`; `nil` stays `nil`.
- **Read side (`Run.rehydrate/1`):** the existing `FailureRecorded` clause
  reconstructs the tuple via an **explicit literal map** on `"action"`
  (`"edit_plan" -> :edit_plan`), **not** `String.to_existing_atom`, for
  cold-boot safety (Projector replays open runs at boot before dependent modules
  load — same reason `step_kind_atom`/`phase_atom`/`surface_atom` use literal
  maps). `nil` passes through. This replaces the current
  `safe_atom(event.repair_action)` call. `failure_code` stays an atom via the
  existing `safe_atom/1` path (the five new codes are `PlanVerifier` module
  attributes, loaded by the time a planner run fails).

`decider.ex` is **not** touched: its `RecordFailure` clause already passes
`repair_action` through verbatim into `FailureRecorded`.

### 2. Receipt rendering (`ToreWeb.Components.ReceiptLive`)

- `failure_message/1` gains one localized clause per code (gettext), naming what
  blocked the action without exposing tool internals or blaming the model (§A.5):
  - `:slot_pinned` → *"That day is pinned, so Tore left it as it was."*
  - `:servings_missing` → *"A meal was missing servings, so nothing was changed."*
  - `:skip_not_explicit` → *"Tore couldn't tell which day to skip."*
  - `:leftover_no_source` → *"There was no earlier meal to make leftovers from."*
  - `:dietary_violation` → *"A suggested recipe didn't fit your household's needs."*
  - existing `:internal_error` clause and catch-all fallback stay.
- A new repair-link element: when the Failed run's `failure_repair_action` is
  `{:edit_plan, slots}`, render an "Edit the plan" link (gettext) navigating to
  the planner with the slots as a query param. The Failed-state dismiss already
  exists.
- Swedish translations for every new msgid, **stripping the `fuzzy` flag** after
  filling each msgstr (the fuzzy trap; test env runs in `sv`).

### 3. Planner slot focus (`ToreWeb.PlannerLive`)

- Add `handle_params/3` accepting a `focus` query param:
  `/plan?focus=mon_dinner,fri_dinner`. Parse into a `focused_slots` MapSet
  assigned to the socket (default empty set; `mount/3` assigns the empty set so
  the template never sees a missing assign).
- `day_row/1` (the slot `<li>`) receives `focused_slots`; when its `slot_key` is
  in the set it adds a highlight class and an `id={"slot-#{@slot_key}"}` anchor.
- A small `JS`/`phx-hook` scrolls the first focused slot into view on mount of
  the focused render. Net-new UI that realizes the full manual-edit affordance.

## Part 2 testing

- **PlanVerifier unit tests** (pure, table-driven): per code, one passing + one
  failing case asserting the exact `{:fail, code, {:edit_plan, slots}}`. Check 5
  uses real `Recipes` fixtures with a known allergen/restriction.
- **Orchestrator integration:** a Mock loop whose PlanDiff violates a pin →
  run ends `State.Failed`, `failure_code: :slot_pinned`, **no `Committed`
  event**, and **the plan stream is empty** (verify-then-mutate: nothing
  applied). Plus: the happy path still applies + commits → `:applied`.
- **Round-trip:** `FailureRecorded` carrying `{:edit_plan, [...]}` survives
  `Run.load` (cold-boot literal-map decode).
- **ReceiptLive:** Failed renders the correct localized message per code + the
  edit link with the correct href (`sv` assertions).
- **PlannerLive:** the `focus` param produces highlighted slots in the render.

---

## File structure

```
# Part 1 — purity / verify-then-mutate
Modify: lib/tore/handlers/planning_handler.ex    # extract pure swap_events/3 (swap_slots/3 wraps it); add apply_events/2 (append accumulated events + broadcast; [] → :ok)
        lib/tore/llm/planner_tools.ex            # 6 action tools → pure 3-arity (decide+evolve, swap via swap_events/3); read tools/ask_user → 3-arity passthrough
        lib/tore/llm/planner_agent.ex            # loop carries working_plan + plan_events; 3-arity tool calls; loop_outcome gains both
        lib/tore/harness/orchestrator.ex         # load working_plan into agent ctx; close/4 calls apply_events before artifacts

# Part 2 — PlanVerifier + surfacing
New:    lib/tore/harness/verifier/plan_verifier.ex
Modify: lib/tore/harness/orchestrator.ex         # verify gate in close/4 (before apply_events); assemble verify_ctx
        lib/tore/harness/run.ex                  # prepare/1 encodes repair_action tuple; rehydrate/1 decodes via literal map
        lib/tore_web/components/receipt_live.ex   # per-code failure_message clauses + edit link
        lib/tore_web/live/planner_live.ex         # handle_params focus → focused_slots → highlight + scroll
        priv/gettext/en/LC_MESSAGES/default.po
        priv/gettext/sv/LC_MESSAGES/default.po

# Tests
New:    test/tore/harness/verifier/plan_verifier_test.exs
Modify: test/tore/llm/planner_tools_test.exs      # pure-tool contract
        test/tore/llm/planner_agent_test.exs       # working_plan/plan_events threading
        test/tore/harness/orchestrator_test.exs     # apply-once; verifier-fail leaves plan empty; happy path
        test/tore/handlers/planning_handler_test.exs # swap_events/3 pure; apply_events/2
        test/tore_web/components/receipt_live_test.exs  # per-code message + edit link (sv)
        test/tore_web/live/planner_live_test.exs    # focus param highlights slots
```

## Open follow-ups (out of scope)

- Add `repeat_window` household preference + `PlanVerifier` check 6.
- Remaining V1 verifiers as their run kinds ship; extract a shared `Verifier`
  contract once a second implementer exists.
