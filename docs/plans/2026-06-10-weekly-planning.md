# Weekly Auto-Planning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a headless `:weekly_planning_run` harness run that fills empty, unpinned dinner slots of the upcoming week via the existing pure planner tool loop, triggered by the Saturday cron, replacing the old pin-clobbering `generate_plan` path.

**Architecture:** Extract the shared planner-loop sequence (load plan → run agent → absorb → verify → close) into a private `run_planner_loop/6` helper in the Orchestrator; `:planner_command_run` and the new `:weekly_planning_run` are thin clauses over it, differing only in the Open command, the agent's user-text, and the loop caps. A new `PlanningHandler.plan_upcoming_week/0` is the cron entry. The old `generate_plan` / `GeneratePlan` / `PlanGenerated` path and its Prep-page button are removed.

**Tech Stack:** Elixir, ExUnit, Mox (`Tore.MockLLM`), Quantum (`Tore.Scheduler`). No new deps. Model-facing English prompts — no gettext.

**Spec:** `docs/specs/2026-06-10-weekly-planning-design.md`

---

## Codebase orientation (read before starting)

- **VCS is jj, never git.** The controller commits per task (`jj describe -m` then `jj new`); do not run git or jj yourself unless the task says so.
- **`Tore.Harness.Orchestrator.dispatch/2`** has one clause today: `dispatch(:planner_command_run, ctx)` (lib/tore/harness/orchestrator.ex:31). Its body is `try`/`with`/`rescue`, then a `case` that calls `record_failure/2` on error. The `with` chain is: `open_run` → `enter(:gathering_context)` → `enter(:proposing)` → `PlanningHandler.load_plan` → `PlannerAgent.run(system_prompt(ctx), ctx.command, agent_ctx(ctx, stream_id, working_plan), [])` → `absorb_loop` → `enter(:verifying)` → `close`.
- **`open_run/3`** (line 75) hardcodes `kind: "planner_command_run"`, `surface: :plan`, `started_by: "user"`, and `input: %{command:, plan_stream_id:, week_start:}`. The weekly run needs a different `kind`/`started_by`/`input` (no `command`).
- **`system_prompt(ctx)`** (after the A.4 work) composes `agent_preamble()` + `date_line()` + `week_mode_line()` + `Capsules.compose(@planner_capsules, capsule_ctx(ctx))`. It is reused as-is by both runs.
- **`agent_ctx(ctx, stream_id, working_plan)`** builds `%{plan_id:, week_start:, household_id:, run_stream_id:, working_plan:}`. Reused as-is.
- **`PlannerAgent.run/4`** is `run(system_prompt, user_text, ctx, opts)`. `opts` supports `max_round_trips:` (default 6) and `max_action_calls:` (default 12).
- **`close/4`** pattern-matches the loop result: `{:message, _}` / `{:capped, _}` → `verify_and_finish` (apply + verify); `{:question, q}` → `RaiseQuestion`. A successful committed run returns `{:ok, %State.Applied{}}`.
- **`PlanningHandler.load_plan(plan_id)`** → `{:ok, %Tore.Planning.State{}}` | `{:error, _}`. `State` has `slots` (map `slot_key => %{recipe_id, servings, skipped, leftover}`) and `pins` (map).
- **`Tore.Household.get_household!/0`** returns the single household (has `.id`).
- **Live Quantum schedule:** `config/config.exs:58` `config :tore, Tore.Scheduler, jobs: [...]`. The Sat 18:00 entry (line ~63) is `{"0 18 * * 6", {fn -> Tore.Handlers.PlanningHandler.generate_plan("plan:current", Date.utc_today()) end}}` (an anonymous-function job).
- **The old path to remove:** `PlanningHandler.generate_plan/3` (line 13) + private `build_plan_context/4` + `parse_llm_slots/1`; `Planning.Commands.GeneratePlan`; `Planning.Events.PlanGenerated` + its `Decider.decide`/`evolve` clauses; `@llm.generate_plan/1` (`Tore.LLM` callback + `Tore.Adapters.OpenRouter` impl + Mock expectations); the `:generate_plan` SpendGuard `@feature_defaults` entry; `prep_live.ex` "generate_plan" `handle_event` + button; `settings_live.ex` `feature_label("generate_plan")`.
- **Independent, DO NOT TOUCH:** `PrepHandler.generate_guide` (reads the plan, calls `@llm.generate_prep_guide`, SpendGuard key `:generate_prep_guide`) and the Prep "generate guide" button. The prep guide is unrelated to plan generation.

`plan_stream_id` convention: `"plan:<iso8601 week_start>"` (e.g. `"plan:2026-06-15"`).

---

## File Structure

This plan modifies the Orchestrator (shared helper + new clause), PlanningHandler (cron entry + removal), the Planning aggregate (remove GeneratePlan/PlanGenerated), the LLM surface (remove the callback + impl), SpendGuard, two LiveViews (remove the Prep plan button + its Settings label), and the Quantum config. It adds one new test file. Removal and addition are interleaved so the suite stays green at each commit.

---

### Task 1: Extract the shared `run_planner_loop` helper (pure refactor of the planner run)

**Files:**
- Modify: `lib/tore/harness/orchestrator.ex`

Goal: factor the planner dispatch into (a) a `run_dispatch/4` wrapper owning the `try/rescue` + `record_failure`, (b) a parameterized `open_run`, and (c) a `run_planner_loop/6` helper owning the load→run→absorb→verify→close sequence. `:planner_command_run` is rewritten to use them with **identical behaviour** — proven by the existing tests staying green. No new run kind yet.

- [ ] **Step 1: Run the existing orchestrator tests to capture the green baseline**

Run: `mix test test/tore/harness/orchestrator_test.exs test/tore/harness/orchestrator_system_prompt_test.exs test/tore_web/live/planner_live_test.exs`
Expected: all PASS. (This is the regression net for the refactor — note the counts.)

- [ ] **Step 2: Parameterize `open_run` to take a prebuilt Open command**

Each dispatch clause will build its own `%Commands.Open{}` (they differ in `kind`/`started_by`/`input`) and pass it in. Replace the current `open_run/3` (lib/tore/harness/orchestrator.ex:75-90), which hardcodes the planner's Open command:

```elixir
  defp open_run(sid, ctx, metadata) do
    cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "planner_command_run",
      surface: :plan,
      started_by: "user",
      user_id: ctx.user_id,
      input: %{
        command: ctx.command,
        plan_stream_id: ctx.plan_stream_id,
        week_start: ctx.week_start
      }
    }

    apply_command(sid, cmd, %State.Draft{stream_id: sid}, metadata)
  end
```

with a version that accepts the already-built command:

```elixir
  defp open_run(sid, %Commands.Open{} = cmd, metadata) do
    apply_command(sid, cmd, %State.Draft{stream_id: sid}, metadata)
  end
```

- [ ] **Step 3: Add the `run_dispatch/4` wrapper and `run_planner_loop/6` helper**

Add these private functions (place them near the existing dispatch, after the `dispatch(:planner_command_run, …)` clause you are about to rewrite):

```elixir
  # Owns the crash boundary + failure-close shared by every planner-style run.
  defp run_dispatch(stream_id, metadata, kind, fun) do
    result =
      try do
        fun.()
      rescue
        e ->
          Logger.error(
            "#{kind} crashed: " <> Exception.format(:error, e, __STACKTRACE__)
          )

          {:error, {:run_crashed, e}}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, _} = err ->
        record_failure(stream_id, metadata)
        err
    end
  end

  # The shared planner loop: load the working plan, run the agent over it,
  # absorb the trace/usage, verify, and close. `user_text` and `opts` are the
  # only per-run variation (the command string vs. the weekly instruction; the
  # default caps vs. the higher weekly caps).
  defp run_planner_loop(state, ctx, stream_id, user_text, opts, metadata) do
    with {:ok, working_plan} <- PlanningHandler.load_plan(ctx.plan_stream_id),
         {:ok, loop} <-
           PlannerAgent.run(
             system_prompt(ctx),
             user_text,
             agent_ctx(ctx, stream_id, working_plan),
             opts
           ),
         {:ok, state} <- absorb_loop(state, loop, metadata),
         {:ok, state} <- enter(state, :verifying, metadata),
         {:ok, state} <- close(state, loop, ctx, metadata) do
      {:ok, state}
    end
  end
```

- [ ] **Step 4: Rewrite the `:planner_command_run` clause to use them**

Replace the whole `dispatch(:planner_command_run, ctx)` clause (lines 31-73) with:

```elixir
  def dispatch(:planner_command_run, ctx) do
    stream_id = Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}

    open_cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "planner_command_run",
      surface: :plan,
      started_by: "user",
      user_id: ctx.user_id,
      input: %{
        command: ctx.command,
        plan_stream_id: ctx.plan_stream_id,
        week_start: ctx.week_start
      }
    }

    run_dispatch(stream_id, metadata, "planner_command_run", fn ->
      with {:ok, state} <- open_run(stream_id, open_cmd, metadata),
           {:ok, state} <- enter(state, :gathering_context, metadata),
           {:ok, state} <- enter(state, :proposing, metadata),
           {:ok, state} <-
             run_planner_loop(state, ctx, stream_id, ctx.command, [], metadata) do
        {:ok, state}
      else
        {:error, reason} -> {:error, {:step_failed, reason}}
      end
    end)
  end
```

- [ ] **Step 5: Run the regression net — behaviour must be identical**

Run: `mix test test/tore/harness/orchestrator_test.exs test/tore/harness/orchestrator_system_prompt_test.exs test/tore_web/live/planner_live_test.exs`
Expected: all PASS, same counts as Step 1. Then `mix compile --warnings-as-errors` — no warnings.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(harness): extract run_dispatch + run_planner_loop from planner clause"
jj new
```

---

### Task 2: Add the `:weekly_planning_run` dispatch clause

**Files:**
- Modify: `lib/tore/harness/orchestrator.ex`
- Test: `test/tore/harness/weekly_planning_run_test.exs`

The new clause opens a run with `kind: "weekly_planning_run"`, then calls `run_planner_loop` with the fixed weekly instruction and higher caps.

- [ ] **Step 1: Write the failing test**

Create `test/tore/harness/weekly_planning_run_test.exs`:

```elixir
defmodule Tore.Harness.WeeklyPlanningRunTest do
  use Tore.DataCase, async: false
  import Mox

  setup :verify_on_exit!

  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State
  alias Tore.{Handlers.PlanningHandler, Recipes}

  defp ctx_for(week_start) do
    %{
      household_id: Tore.Household.get_household!().id,
      user_id: nil,
      plan_stream_id: "plan:#{Date.to_iso8601(week_start)}",
      week_start: week_start
    }
  end

  test "fills empty unpinned slots and leaves pinned + assigned slots untouched" do
    week_start = ~D[2026-06-15]
    ctx = ctx_for(week_start)

    {:ok, chosen} =
      Recipes.create(%{
        title: "Lentil stew",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: 30
      })

    {:ok, pinned_recipe} =
      Recipes.create(%{
        title: "Pinned pasta",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 5,
        cook_time_minutes: 15
      })

    # mon is pre-assigned + pinned; tue is pre-assigned (not pinned, but already has a meal)
    PlanningHandler.assign_recipe(ctx.plan_stream_id, "mon_dinner", pinned_recipe.id, 4)
    PlanningHandler.pin_slot(ctx.plan_stream_id, "mon_dinner", true)
    PlanningHandler.assign_recipe(ctx.plan_stream_id, "tue_dinner", chosen.id, 4)

    # the model fills one empty slot (wed) and then stops
    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "assign_recipe",
            args: %{"slot" => "wed_dinner", "recipe_id" => chosen.id, "servings" => 4}
          }
        ]}, %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.0001}}
    end)
    |> Mox.expect(:chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Filled the week."}, %{prompt_tokens: 4, completion_tokens: 2, cost_usd: 0.0}}
    end)

    assert {:ok, %State.Applied{}} = Orchestrator.dispatch(:weekly_planning_run, ctx)

    {:ok, plan} = PlanningHandler.load_plan(ctx.plan_stream_id)
    assert plan.slots["wed_dinner"].recipe_id == chosen.id
    assert plan.slots["mon_dinner"].recipe_id == pinned_recipe.id
    assert Map.has_key?(plan.pins, "mon_dinner")
    assert plan.slots["tue_dinner"].recipe_id == chosen.id
  end
end
```

> **Implementer note:** the exact `assign_recipe` tool arg keys (`"slot"` vs `"slot_key"`, whether it takes a raw `recipe_id` or a resolver handle) must match the REAL planner tool schema in `lib/tore/llm/planner_tools.ex`. Read that file and adjust the mock's `args` map to whatever the actual `assign_recipe` tool expects. Do not invent keys. If the tool requires a resolver handle (per §A.6.2), the mock must first call the resolver tool — read the tool definitions and mirror how the existing planner tests in `planner_live_test.exs` drive a tool call.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/harness/weekly_planning_run_test.exs`
Expected: FAIL — no `dispatch(:weekly_planning_run, ...)` clause (a `FunctionClauseError` or no-clause-matching error).

- [ ] **Step 3: Add the dispatch clause + the instruction builder**

Add after the `:planner_command_run` clause in `lib/tore/harness/orchestrator.ex`:

```elixir
  @weekly_max_round_trips 10
  @weekly_max_action_calls 25

  def dispatch(:weekly_planning_run, ctx) do
    stream_id = Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}

    open_cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "weekly_planning_run",
      surface: :plan,
      started_by: "system",
      user_id: ctx.user_id,
      input: %{
        plan_stream_id: ctx.plan_stream_id,
        week_start: ctx.week_start
      }
    }

    opts = [max_round_trips: @weekly_max_round_trips, max_action_calls: @weekly_max_action_calls]

    run_dispatch(stream_id, metadata, "weekly_planning_run", fn ->
      with {:ok, state} <- open_run(stream_id, open_cmd, metadata),
           {:ok, state} <- enter(state, :gathering_context, metadata),
           {:ok, state} <- enter(state, :proposing, metadata),
           {:ok, state} <-
             run_planner_loop(state, ctx, stream_id, weekly_fill_instruction(), opts, metadata) do
        {:ok, state}
      else
        {:error, reason} -> {:error, {:step_failed, reason}}
      end
    end)
  end
```

And add the instruction builder near `agent_preamble/0`:

```elixir
  defp weekly_fill_instruction do
    """
    Fill every empty, unplanned dinner this week with a suitable recipe. Leave
    days that already have a meal, and days the household has pinned, exactly as
    they are. Use leftovers across days where it makes sense. When you are done,
    stop.
    """
  end
```

> **Implementer note:** verify `%Commands.Open{}` accepts `started_by: "system"` and an `input` without a `:command` key. Read `lib/tore/harness/run/commands.ex` (the `Open` defstruct) and `lib/tore/harness/run/decider.ex` (its `Open` handling) — if `started_by` is a constrained enum or `input.command` is required downstream, adjust to a valid value and report it. If the Decider validates `kind` against a known set, add `"weekly_planning_run"` there.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/harness/weekly_planning_run_test.exs`
Expected: PASS (1 test). If the mock tool-args were wrong, fix per the Step 1 note until green.

- [ ] **Step 5: Compile clean + planner regression**

Run: `mix compile --warnings-as-errors` then `mix test test/tore/harness/ test/tore_web/live/planner_live_test.exs`
Expected: no warnings; all PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(harness): :weekly_planning_run — headless slot-fill over the planner loop"
jj new
```

---

### Task 3: Add `PlanningHandler.plan_upcoming_week/0` (cron entry)

**Files:**
- Modify: `lib/tore/handlers/planning_handler.ex`
- Test: `test/tore/handlers/planning_handler_test.exs`

A zero-arity function the cron calls: resolve the household, compute the upcoming Monday, dispatch `:weekly_planning_run`.

- [ ] **Step 1: Write the failing test**

Add to `test/tore/handlers/planning_handler_test.exs`:

```elixir
  test "plan_upcoming_week dispatches a weekly run for the upcoming Monday-start week" do
    import Mox

    # the run will drive the agent loop; a single terminal message is enough here
    Tore.MockLLM
    |> expect(:chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Nothing to do."}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    today = Date.utc_today()
    days_until_next_monday = rem(8 - Date.day_of_week(today), 7)
    days_until_next_monday = if days_until_next_monday == 0, do: 7, else: days_until_next_monday
    expected_week_start = Date.add(today, days_until_next_monday)
    expected_stream = "plan:#{Date.to_iso8601(expected_week_start)}"

    assert {:ok, state} = Tore.Handlers.PlanningHandler.plan_upcoming_week()
    # the run committed against the upcoming-week plan stream
    assert state.__struct__ == Tore.Harness.Run.State.Applied
    {:ok, _plan} = Tore.Handlers.PlanningHandler.load_plan(expected_stream)
  end
```

> **Implementer note:** "upcoming week" = the next Monday strictly after today (if today is Monday, plan the *next* Monday, not today). Confirm this matches the helper you write. If the project already has a week-start helper (grep for `beginning_of_week`, `day_of_week`, `week_start` in `lib/tore`), reuse it rather than re-deriving — but the cron must target the UPCOMING week, not the current one.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/handlers/planning_handler_test.exs -k "plan_upcoming_week"` (or run the file)
Expected: FAIL — `plan_upcoming_week/0` undefined.

- [ ] **Step 3: Implement `plan_upcoming_week/0`**

Add to `lib/tore/handlers/planning_handler.ex` (alias `Tore.Harness.Orchestrator` and `Tore.Household` at the top if not already aliased):

```elixir
  @doc """
  Cron entry: plan the upcoming week (next Monday–Sunday) for the household by
  dispatching a headless `:weekly_planning_run`.
  """
  def plan_upcoming_week do
    household = Tore.Household.get_household!()
    today = Date.utc_today()
    days_ahead = rem(8 - Date.day_of_week(today), 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    week_start = Date.add(today, days_ahead)

    ctx = %{
      household_id: household.id,
      user_id: nil,
      plan_stream_id: "plan:#{Date.to_iso8601(week_start)}",
      week_start: week_start
    }

    Tore.Harness.Orchestrator.dispatch(:weekly_planning_run, ctx)
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/handlers/planning_handler_test.exs`
Expected: the new test PASSES. (Pre-existing `generate_plan` tests in this file still pass for now — they are removed in Task 5.)

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(planning): plan_upcoming_week/0 — cron entry dispatching the weekly run"
jj new
```

---

### Task 4: Re-point the Saturday Quantum job

**Files:**
- Modify: `config/config.exs` (the `Tore.Scheduler` jobs list, Sat 18:00 entry ~line 63)

- [ ] **Step 1: Replace the Sat 18:00 job**

In `config/config.exs`, change:

```elixir
    {"0 18 * * 6",
     {fn ->
        Tore.Handlers.PlanningHandler.generate_plan("plan:current", Date.utc_today())
      end}},
```

(or whatever the exact current anonymous-function form is) to:

```elixir
    {"0 18 * * 6", {Tore.Handlers.PlanningHandler, :plan_upcoming_week, []}},
```

> **Implementer note:** match the exact tuple syntax Quantum uses elsewhere in this list — the file already has `{"0 8 * * 6", {Tore.Handlers.DealsHandler, :scrape_all, []}}`-style MFA entries; use that MFA form. Leave the `30 18 * * 6` prep-guide job untouched.

- [ ] **Step 2: Compile + confirm the scheduler config loads**

Run: `mix compile --warnings-as-errors`
Expected: no warnings. (Quantum validates the job list at boot; a malformed entry would raise — a clean compile + the app-boot tests in the suite cover this.)

- [ ] **Step 3: Commit**

```bash
jj describe -m "chore(scheduler): re-point Sat 18:00 job at plan_upcoming_week"
jj new
```

---

### Task 5: Remove the old `generate_plan` path

**Files:**
- Modify: `lib/tore/handlers/planning_handler.ex` (remove `generate_plan/3` + `build_plan_context/4` + `parse_llm_slots/1`)
- Modify: `lib/tore/planning/commands.ex` (remove `GeneratePlan`)
- Modify: `lib/tore/planning/events.ex` (remove `PlanGenerated`)
- Modify: `lib/tore/planning/decider.ex` (remove the `GeneratePlan` decide + `PlanGenerated` evolve clauses)
- Modify: `lib/tore/llm.ex` (remove `@callback generate_plan/1`)
- Modify: `lib/tore/adapters/open_router.ex` (remove `generate_plan/1`)
- Modify: `lib/tore/spend_guard.ex` (remove `:generate_plan` from `@feature_defaults`)
- Modify/Delete tests: `test/tore/handlers/planning_handler_test.exs` (generate_plan cases), `test/tore/adapters/open_router_test.exs` (generate_plan case), `test/tore/spend_guard_test.exs` (the `:generate_plan` key)

- [ ] **Step 1: Delete the generate_plan tests first (red→green by removal)**

Remove the `generate_plan` test blocks from `test/tore/handlers/planning_handler_test.exs` (the four tests at ~lines 52-100: "calls LLM…", "broadcasts PlanGenerated", "returns error when LLM fails", "returns budget_exceeded…") and the `generate_plan` test in `test/tore/adapters/open_router_test.exs`. In `test/tore/spend_guard_test.exs`, change the `:generate_plan` feature key in its tests to `:generate_prep_guide` (a real remaining key) OR to an arbitrary atom — the SpendGuard tests verify the guard mechanism, not the feature; pick `:generate_prep_guide` so it stays meaningful.

- [ ] **Step 2: Remove the production code**

In dependency order (remove callers before callees so each intermediate compile is clean):

1. `lib/tore_web/live/prep_live.ex`: delete the `handle_event("generate_plan", …)` clause (~lines 23-35) and the `phx-click="generate_plan"` button in the template (~line 109). (Task 6 also touches prep_live for the Settings label; doing the button here keeps the removal cohesive — but the Settings label is Task 6.)

   > Actually do the prep_live button removal here so `generate_plan` has no UI caller before you delete the handler. Leave `settings_live.ex` to Task 6.

2. `lib/tore/handlers/planning_handler.ex`: delete `generate_plan/3` and its private-only helpers `build_plan_context/4` and `parse_llm_slots/1`. (Grep first: `grep -n "build_plan_context\|parse_llm_slots" lib/` — if either has another caller, leave that one.)

3. `lib/tore/planning/decider.ex`: delete the `decide(%Commands.GeneratePlan{...}, _state)` clause and the `evolve(state, %Events.PlanGenerated{...})` clause.

4. `lib/tore/planning/commands.ex`: remove the `GeneratePlan` defmodule and its entry in the `t()` union type.

5. `lib/tore/planning/events.ex`: remove the `PlanGenerated` defmodule and its entry in the `t()` union type.

6. `lib/tore/llm.ex`: remove `@callback generate_plan/1`.

7. `lib/tore/adapters/open_router.ex`: remove `def generate_plan/1`.

8. `lib/tore/spend_guard.ex`: remove the `generate_plan: {50_000, 60},` line from `@feature_defaults`.

- [ ] **Step 3: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean. If you get "function generate_plan/1 undefined" or "unused" warnings, you missed a reference — grep `grep -rn "generate_plan\|GeneratePlan\|PlanGenerated" lib/` and resolve each (the only remaining hits should be `:generate_prep_guide` which is a different name — verify the grep matches whole identifiers).

- [ ] **Step 4: Full suite**

Run: `mix test`
Expected: all green. The `Tore.MockLLM` may still declare `generate_plan` in its stub list — if Mox complains about an undefined-in-behaviour stub, remove the `generate_plan` stub from the test mock setup (grep `grep -rn "generate_plan" test/support test/test_helper.exs`).

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(planning): remove old generate_plan/GeneratePlan/PlanGenerated path"
jj new
```

---

### Task 6: Remove the dangling Settings label + final verification

**Files:**
- Modify: `lib/tore_web/live/settings_live.ex` (remove `feature_label("generate_plan")`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Remove the Settings feature label**

In `lib/tore_web/live/settings_live.ex`, delete the clause:

```elixir
  defp feature_label("generate_plan"), do: gettext("Plan generation")
```

> **Implementer note:** confirm `feature_label/1` has a catch-all/default clause so removing this one doesn't make some other call raise. If `"generate_plan"` could still appear in the costs/feature UI from historical `ai_operations` rows, KEEP this clause (it's a display label for past data, not a live caller). Grep `grep -rn "generate_plan" lib/tore_web` and check the Costs/Settings rendering — if historical rows reference it, leave the label and note this as DONE_WITH_CONCERNS instead of removing.

- [ ] **Step 2: Compile + full suite**

Run: `mix compile --warnings-as-errors && mix test`
Expected: clean compile, all green.

- [ ] **Step 3: Format**

Run: `mix format` then `jj diff --stat` to confirm only intended files changed.

- [ ] **Step 4: Append to CHANGELOG**

Add under the `## [Unreleased]` section of `CHANGELOG.md`, after the context-capsules entry:

```markdown
### Weekly auto-planning (§:weekly_planning_run, PlanMyWeek)

A headless harness run that fills the upcoming week's empty, unpinned dinner
slots, triggered by the Saturday cron.

- `:weekly_planning_run` reuses the planner's pure tool loop, the four context
  capsules, and `PlanVerifier`, via an extracted `run_planner_loop` helper shared
  with `:planner_command_run`. Higher loop caps (10 round-trips / 25 action
  calls). Fills empty + unpinned slots only; pinned and assigned days are left
  untouched; the apply is atomic (verifier-gated).
- `PlanningHandler.plan_upcoming_week/0` is the cron entry; the Saturday 18:00
  Quantum job now targets the upcoming (next Mon–Sun) week via the harness. The
  result surfaces through the Projector when the user next opens `/plan`; they
  edit individual slots with the existing modal.
- Removed the old one-shot `generate_plan` path — `PlanningHandler.generate_plan/3`,
  `Planning.Commands.GeneratePlan`, `Planning.Events.PlanGenerated` (whose evolve
  clobbered pins), the `@llm.generate_plan/1` callback + adapter impl, the
  `:generate_plan` SpendGuard entry, and the Prep page's "generate plan" button.
  The prep *guide* (`PrepHandler.generate_guide`) is independent and unchanged.
```

- [ ] **Step 5: Commit**

```bash
jj describe -m "chore: remove generate_plan Settings label + CHANGELOG for weekly planning"
jj new
```

---

## Notes for the executor

- **jj, never git.** One `jj describe` + `jj new` per task. Push to master happens after the whole plan + final review, via finishing-a-development-branch.
- **Smoke tests are user-run.** Do not run live-LLM smoke tests; Mox covers the deterministic paths. The key is the user's; never read it.
- **No i18n.** The weekly instruction + capsule prompts are model-facing English. The only gettext touched is the *removal* of a feature label — and only if it has no historical-display use (see Task 6 note).
- **Confirm-before-invent:** Tasks 2 and 3 require reading the real planner-tool arg schema (`planner_tools.ex`) and the `Commands.Open` shape (`run/commands.ex` + `run/decider.ex`) before writing test mocks / the Open command. Match reality; do not invent keys or enum values.
- **Behaviour-preserving refactor (Task 1):** the planner run's tests are the contract. If any change in Task 1, the refactor is wrong — revert and redo, do not "fix" the tests.
