# Pure Planner Loop + PlanVerifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `:planner_command_run` verify-then-mutate — action tools propose against an in-memory plan, the Orchestrator applies once after the loop, and a new `PlanVerifier` gates that apply so a failure leaves the plan genuinely unchanged.

**Architecture:** Part 1 turns the planner loop pure: tools call the existing `Planning.Decider` against a working `Planning.State` threaded through the agent loop, returning `{:ok, result, events, next_plan}`; the Orchestrator persists the accumulated events once via a new `PlanningHandler.apply_events/2`. Part 2 drops a pure `PlanVerifier.verify/2` into that seam before the apply step; failures record `State.Failed` with a structured code and an `{:edit_plan, slots}` repair action surfaced as a localized receipt + planner slot-focus.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/SQLite event store, Mox, gettext (en/sv). VCS is **jj** (Jujutsu), never git. Push to master per repo convention.

**Spec:** `docs/specs/2026-06-08-plan-verifier-design.md`

---

## Conventions for every task

- Tests: `mix test <path>`; full suite `mix test`. Test env runs in `sv` locale.
- Commit each task with jj: `jj describe -m "<msg>"` then `jj new` to start the next change. Do **not** push per-task; the controller pushes at the end.
- Tiger naming: verb-first function names.
- Touch only what the task requires (CLAUDE.md). No speculative abstractions.

---

# PART 1 — Pure planner loop / verify-then-mutate seam

### Task 1: Extract pure `swap_events/3` from `swap_slots/3`

**Files:**

- Modify: `lib/tore/handlers/planning_handler.ex` (the `swap_slots/3` function, ~line 94, and private `swap_commands/4`/`present/1`)
- Test: `test/tore/handlers/planning_handler_test.exs`

The current `swap_slots/3` loads state, builds commands via `swap_commands/4`, reduces them through `Decider.decide`+`evolve`, then appends. Extract the pure middle (commands + reduce) so tools can reuse it without persisting.

- [ ] **Step 1: Write the failing test**

Add to `test/tore/handlers/planning_handler_test.exs`:

```elixir
describe "swap_events/3 (pure)" do
  alias Tore.Planning.{Decider, State}

  test "returns cross-assign events and the evolved state without persisting" do
    {:ok, r1} = Tore.Recipes.create(%{title: "A", base_servings: 2, instructions: "x"})
    {:ok, r2} = Tore.Recipes.create(%{title: "B", base_servings: 2, instructions: "x"})

    state =
      %State{}
      |> Decider.evolve(%Tore.Planning.Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: r1.id, servings: 2})
      |> Decider.evolve(%Tore.Planning.Events.RecipeAssigned{slot_key: "tue_dinner", recipe_id: r2.id, servings: 2})

    assert {:ok, events, next} = PlanningHandler.swap_events(state, "mon_dinner", "tue_dinner")
    assert events != []
    assert next.slots["mon_dinner"].recipe_id == r2.id
    assert next.slots["tue_dinner"].recipe_id == r1.id
  end

  test "returns :nothing_to_swap when both slots are empty" do
    assert {:error, :nothing_to_swap} =
             PlanningHandler.swap_events(%State{}, "mon_dinner", "tue_dinner")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/handlers/planning_handler_test.exs`
Expected: FAIL — `swap_events/3` undefined.

- [ ] **Step 3: Implement `swap_events/3` and rewrite `swap_slots/3` to use it**

In `lib/tore/handlers/planning_handler.ex`, add the pure function and make the impure one wrap it:

```elixir
@doc "Pure: cross-assign events for swapping two slots in a given plan state."
@spec swap_events(Tore.Planning.State.t(), String.t(), String.t()) ::
        {:ok, [struct()], Tore.Planning.State.t()} | {:error, :nothing_to_swap}
def swap_events(state, slot_a, slot_b) do
  a = present(Map.get(state.slots, slot_a))
  b = present(Map.get(state.slots, slot_b))

  case swap_commands(slot_a, a, slot_b, b) do
    [] ->
      {:error, :nothing_to_swap}

    commands ->
      {events, final} =
        Enum.reduce(commands, {[], state}, fn cmd, {acc, st} ->
          {:ok, evts} = Decider.decide(cmd, st)
          st2 = Enum.reduce(evts, st, &Decider.evolve(&2, &1))
          {acc ++ evts, st2}
        end)

      {:ok, events, final}
  end
end

def swap_slots(plan_id, slot_a, slot_b) do
  with {:ok, state} <- EventStore.load(plan_id, Decider) do
    case swap_events(state, slot_a, slot_b) do
      {:error, :nothing_to_swap} = err ->
        err

      {:ok, events, _final} ->
        with :ok <- EventStore.append(plan_id, events) do
          PubSub.broadcast(@pubsub, @topic, {:events, events})
          {:ok, events}
        end
    end
  end
end
```


- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/handlers/planning_handler_test.exs`
Expected: PASS. Also run the existing swap tests in the suite to confirm `swap_slots/3` still works.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(planning): extract pure swap_events/3 from swap_slots/3"
jj new
```

---

### Task 2: Add `apply_events/2` to `PlanningHandler`

**Files:**

- Modify: `lib/tore/handlers/planning_handler.ex`
- Test: `test/tore/handlers/planning_handler_test.exs`

The Orchestrator will persist the loop's accumulated plan events in one append after the loop.

- [ ] **Step 1: Write the failing test**

```elixir
describe "apply_events/2" do
  test "appends events to the plan stream and returns :ok" do
    {:ok, r} = Tore.Recipes.create(%{title: "C", base_servings: 2, instructions: "x"})
    plan = "plan:apply-test"
    events = [%Tore.Planning.Events.RecipeAssigned{slot_key: "wed_dinner", recipe_id: r.id, servings: 3}]

    assert :ok = PlanningHandler.apply_events(plan, events)
    {:ok, state} = PlanningHandler.load_plan(plan)
    assert state.slots["wed_dinner"].recipe_id == r.id
  end

  test "is a no-op for an empty event list" do
    assert :ok = PlanningHandler.apply_events("plan:empty-apply", [])
    {:ok, state} = PlanningHandler.load_plan("plan:empty-apply")
    assert state.slots == %{}
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/handlers/planning_handler_test.exs`
Expected: FAIL — `apply_events/2` undefined.

- [ ] **Step 3: Implement**

```elixir
@doc "Persist already-decided plan events in one append. Empty list is a no-op."
@spec apply_events(String.t(), [struct()]) :: :ok | {:error, term()}
def apply_events(_plan_id, []), do: :ok

def apply_events(plan_id, events) do
  with :ok <- EventStore.append(plan_id, events) do
    PubSub.broadcast(@pubsub, @topic, {:events, events})
    :ok
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/handlers/planning_handler_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(planning): add apply_events/2 for batched post-loop persistence"
jj new
```

---

### Task 3: Make action tools pure (3-arity contract)

**Files:**

- Modify: `lib/tore/llm/tool.ex` (the `run` type; `validate_args` unchanged)
- Modify: `lib/tore/llm/planner_tools.ex` (all 6 action tools + 3 read tools + ask_user)
- Test: `test/tore/llm/planner_tools_test.exs`

Tools change from `run: fn args, ctx -> {:ok, result} | {:error, reason}` to `run: fn args, ctx, working_plan -> {:ok, result, events, next_plan} | {:error, reason}`. Action tools call `Decider.decide`/`evolve` against `working_plan`; read tools and `ask_user` return `{:ok, result, [], working_plan}`.

- [ ] **Step 1: Rewrite the test file for the pure contract**

The existing tests assert against `PlanningHandler.load_plan` after `tool.run` — that no longer applies (tools don't persist). Rewrite `test/tore/llm/planner_tools_test.exs` to assert on the returned `{events, next_plan}`. Full new file:

```elixir
defmodule Tore.LLM.PlannerToolsTest do
  use Tore.DataCase, async: false
  alias Tore.LLM.PlannerTools
  alias Tore.Planning.{Decider, State, Events}

  @week_start ~D[2026-06-01]

  setup do
    %{ctx: %{plan_id: "plan:test", week_start: @week_start}}
  end

  defp make_recipe(attrs \\ %{}) do
    base = %{title: "Recipe #{System.unique_integer([:positive])}", base_servings: 2, instructions: "x"}
    {:ok, r} = Tore.Recipes.create(Map.merge(base, attrs))
    r
  end

  defp find(name), do: Enum.find(PlannerTools.all(), &(&1.name == name))

  defp with_slot(state, slot, rid),
    do: Decider.evolve(state, %Events.RecipeAssigned{slot_key: slot, recipe_id: rid, servings: 2})

  test "assign_recipe proposes a RecipeAssigned event and evolves the plan", %{ctx: ctx} do
    %{id: rid} = make_recipe(%{title: "Test Salmon"})
    tool = find("assign_recipe")
    args = %{"slot_key" => "mon_dinner", "recipe_id" => rid, "servings" => 2, "rationale" => "good protein"}

    assert {:ok, %{ok: true}, events, next} = tool.run.(args, ctx, %State{})
    assert [%Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: ^rid, servings: 2}] = events
    assert %{recipe_id: ^rid, servings: 2} = next.slots["mon_dinner"]
  end

  test "assign_recipe returns the recipe title as label", %{ctx: ctx} do
    %{id: rid} = make_recipe(%{title: "Roast chicken"})
    tool = find("assign_recipe")
    args = %{"slot_key" => "mon_dinner", "recipe_id" => rid, "servings" => 4, "rationale" => "easy"}

    assert {:ok, %{ok: true, label: "Roast chicken"}, _events, _next} = tool.run.(args, ctx, %State{})
  end

  test "skip_meal on an occupied slot proposes MealSkipped", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "tue_dinner", rid)
    tool = find("skip_meal")

    assert {:ok, %{ok: true}, [%Events.MealSkipped{slot_key: "tue_dinner"}], next} =
             tool.run.(%{"slot_key" => "tue_dinner", "rationale" => "out"}, ctx, state)
    assert next.slots["tue_dinner"].skipped == true
  end

  test "skip_meal on an empty slot returns the Decider error and does not evolve", %{ctx: ctx} do
    tool = find("skip_meal")
    assert {:error, :slot_empty} =
             tool.run.(%{"slot_key" => "fri_dinner", "rationale" => "out"}, ctx, %State{})
  end

  test "remove_recipe clears a slot", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "mon_dinner", rid)
    tool = find("remove_recipe")

    assert {:ok, %{ok: true}, [%Events.RecipeRemoved{slot_key: "mon_dinner"}], next} =
             tool.run.(%{"slot_key" => "mon_dinner", "rationale" => "changed mind"}, ctx, state)
    refute Map.has_key?(next.slots, "mon_dinner")
  end

  test "set_servings changes servings", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "mon_dinner", rid)
    tool = find("set_servings")

    assert {:ok, %{ok: true}, [%Events.ServingsChanged{slot_key: "mon_dinner", servings: 6}], next} =
             tool.run.(%{"slot_key" => "mon_dinner", "servings" => 6, "rationale" => "guests"}, ctx, state)
    assert next.slots["mon_dinner"].servings == 6
  end

  test "mark_leftover marks the slot", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "tue_dinner", rid)
    tool = find("mark_leftover")

    assert {:ok, %{ok: true}, [%Events.LeftoverMarked{slot_key: "tue_dinner"}], next} =
             tool.run.(%{"slot_key" => "tue_dinner", "rationale" => "leftovers"}, ctx, state)
    assert next.slots["tue_dinner"].leftover == true
  end

  test "swap_recipe cross-assigns two slots", %{ctx: ctx} do
    r1 = make_recipe(%{title: "One"})
    r2 = make_recipe(%{title: "Two"})
    state = %State{} |> with_slot("mon_dinner", r1.id) |> with_slot("tue_dinner", r2.id)
    tool = find("swap_recipe")

    assert {:ok, %{ok: true, recipe_id: rid, label: "One"}, events, next} =
             tool.run.(%{"from_slot_key" => "mon_dinner", "to_slot_key" => "tue_dinner", "rationale" => "balance"}, ctx, state)
    assert rid == r1.id
    assert next.slots["tue_dinner"].recipe_id == r1.id
    assert next.slots["mon_dinner"].recipe_id == r2.id
    assert events != []
  end

  test "read tools return the plan unchanged with no events", %{ctx: ctx} do
    tool = find("search_recipes")
    assert {:ok, %{recipes: _}, [], %State{}} = tool.run.(%{"query" => "x"}, ctx, %State{})
  end

  test "ask_user returns the question with the plan unchanged", %{ctx: ctx} do
    tool = find("ask_user")
    assert {:ok, %{ask_user: "which day?"}, [], %State{}} =
             tool.run.(%{"question" => "which day?"}, ctx, %State{})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: FAIL — tools still 2-arity / persist to DB.

- [ ] **Step 3: Update the `Tool.run` type**

In `lib/tore/llm/tool.ex`, change the `run` field type:

```elixir
run: (map(), map(), term() ->
        {:ok, term(), [struct()], term()} | {:error, term()})
```

(`term()` for the working plan keeps `Tool` decoupled from `Planning.State`.)

- [ ] **Step 4: Rewrite the action tools in `planner_tools.ex`**

Add aliases at the top: `alias Tore.Planning.{Decider, Commands, State}`. Keep `alias Tore.Handlers.PlanningHandler` (used by `swap_recipe`). Rewrite each action tool's `run`. Examples — apply the same shape to all six:

```elixir
# assign_recipe
run: fn args, _ctx, plan ->
  cmd = %Commands.AssignRecipe{slot_key: args["slot_key"], recipe_id: args["recipe_id"], servings: args["servings"]}
  propose(cmd, plan, %{ok: true, label: recipe_title(args["recipe_id"])})
end

# skip_meal
run: fn args, _ctx, plan ->
  propose(%Commands.SkipMeal{slot_key: args["slot_key"]}, plan, %{ok: true})
end

# mark_leftover
run: fn args, _ctx, plan ->
  propose(%Commands.MarkLeftover{slot_key: args["slot_key"]}, plan, %{ok: true})
end

# set_servings
run: fn args, _ctx, plan ->
  propose(%Commands.SetServings{slot_key: args["slot_key"], servings: args["servings"]}, plan, %{ok: true})
end

# remove_recipe
run: fn args, _ctx, plan ->
  propose(%Commands.RemoveRecipe{slot_key: args["slot_key"]}, plan, %{ok: true})
end

# swap_recipe (uses the extracted pure helper)
run: fn args, _ctx, plan ->
  case PlanningHandler.swap_events(plan, args["from_slot_key"], args["to_slot_key"]) do
    {:ok, events, next} ->
      to_recipe_id = get_in(next.slots, [args["to_slot_key"], :recipe_id])
      {:ok, %{ok: true, label: recipe_title(to_recipe_id), recipe_id: to_recipe_id}, events, next}

    {:error, reason} ->
      {:error, reason}
  end
end
```

Add the private helper:

```elixir
# Decide one command against the working plan; on success evolve it and return events.
defp propose(cmd, plan, result) do
  case Decider.decide(cmd, plan) do
    {:ok, events} ->
      next = Enum.reduce(events, plan, fn ev, acc -> Decider.evolve(acc, ev) end)
      {:ok, result, events, next}

    {:error, reason} ->
      {:error, reason}
  end
end
```

Update `recipe_title/1` to tolerate a `nil` id (already does: `recipe_title(nil) -> nil`).

- [ ] **Step 5: Update read tools and ask_user to 3-arity**

Change each read tool (`search_recipes`, `pantry_snapshot`, `active_deals`) and `ask_user` to `run: fn args, _ctx, plan ->` and wrap their existing `{:ok, result}` as `{:ok, result, [], plan}`. For example `search_recipes` final line becomes `{:ok, %{recipes: result}, [], plan}`; `ask_user` becomes `{:ok, %{ask_user: args["question"]}, [], plan}`.

Update the moduledoc to reflect that action tools are now pure proposals (no DB writes).

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
jj describe -m "refactor(llm): planner action tools propose against an in-memory plan (pure 3-arity)"
jj new
```

---

### Task 4: Thread the working plan through `PlannerAgent`

**Files:**

- Modify: `lib/tore/llm/planner_agent.ex`
- Test: `test/tore/llm/planner_agent_test.exs`

The loop carries `working_plan` (from `ctx.working_plan`) and `plan_events: []`, calls tools 3-arity, accumulates events, and includes both in `loop_outcome`.

- [ ] **Step 1: Write the failing test**

Add to `test/tore/llm/planner_agent_test.exs`. First, the ctx needs a `working_plan`; existing `@ctx` lacks it. Add a helper and a new test:

```elixir
alias Tore.Planning.{State, Events}

defp ctx_with_plan(plan \\ %State{}),
  do: %{plan_id: "plan-1", week_start: ~D[2026-06-01], household_id: 1, working_plan: plan}

test "run/4 accumulates plan_events and evolves working_plan across the loop" do
  {:ok, r} = Tore.Recipes.create(%{title: "Z", base_servings: 2, instructions: "x"})
  rid = r.id
  start_plan = Decider.evolve(%State{}, %Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: rid, servings: 2})

  expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
    {:ok, {:tool_calls, [%{id: "c1", name: "skip_meal", args: %{"slot_key" => "mon_dinner", "rationale" => "out"}}]},
     %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
    {:ok, {:message, "Done."}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  {:ok, outcome} = PlannerAgent.run(@system_prompt, "skip mon", ctx_with_plan(start_plan), [])

  assert [%Events.MealSkipped{slot_key: "mon_dinner"}] = outcome.plan_events
  assert outcome.working_plan.slots["mon_dinner"].skipped == true
end
```

Add `alias Tore.Planning.Decider` to the test aliases. Update existing tests that build `@ctx` to include `working_plan: %State{}` (or switch them to `ctx_with_plan()`), since the loop now reads it.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: FAIL — `outcome.plan_events` missing / KeyError on `ctx.working_plan` or arity mismatch.

- [ ] **Step 3: Implement loop threading**

In `lib/tore/llm/planner_agent.ex`:

In `run/4`, add to the initial `state` map:

```elixir
working_plan: Map.fetch!(ctx, :working_plan),
plan_events: [],
```

Update `@type loop_outcome` to add `working_plan: term()` and `plan_events: [struct()]`.

In `handle_tool` for `ask_user`, change the call and result:

```elixir
defp handle_tool(%Tool{name: "ask_user"} = tool, call, _rest, state) do
  case Tool.validate_args(tool, call.args) do
    :ok ->
      {:ok, %{ask_user: question}, [], _plan} = tool.run.(call.args, state.ctx, state.working_plan)
      state = append_tool_result(state, call, %{ok: true, question: question})
      {:terminal_question, question, state}

    {:error, _} = err ->
      {:continue, append_tool_result(state, call, %{error: inspect(err)})}
  end
end
```

Rewrite `run_and_record/4` to call 3-arity and absorb events/plan:

```elixir
defp run_and_record(tool, call, rest, state) do
  case Tool.validate_args(tool, call.args) do
    :ok ->
      case tool.run.(call.args, state.ctx, state.working_plan) do
        {:ok, result, events, next_plan} ->
          state = %{state | working_plan: next_plan, plan_events: state.plan_events ++ events}
          execute_calls(rest, append_tool_result(state, call, result))

        {:error, reason} ->
          execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
      end

    {:error, reason} ->
      execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
  end
end
```

In `finish/2`, add the two fields to the returned map:

```elixir
defp finish(state, result) do
  {:ok,
   %{
     result: result,
     tool_trace: Enum.reverse(state.tool_trace),
     usage_per_step: Enum.reverse(state.usage_per_step),
     working_plan: state.working_plan,
     plan_events: state.plan_events
   }}
end
```

Update the moduledoc note if it mentions tool arity.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(llm): PlannerAgent threads a working plan + accumulates plan_events"
jj new
```

---

### Task 5: Orchestrator loads the working plan and applies events after the loop

**Files:**

- Modify: `lib/tore/harness/orchestrator.ex`
- Test: `test/tore/harness/orchestrator_test.exs`

Load the plan into the agent ctx; in `close/4` (`:message` and `:capped`), persist `loop.plan_events` once via `apply_events/2` **before** adding artifacts.

- [ ] **Step 1: Write the failing test**

Add to `test/tore/harness/orchestrator_test.exs`:

```elixir
test "dispatch applies accumulated plan events to the plan stream exactly once" do
  {:ok, recipe} = Tore.Recipes.create(%{title: "Stew", recipe_type: :meal, base_servings: 4})
  plan = "plan:2026-06-08-apply"
  Tore.Handlers.PlanningHandler.assign_recipe(plan, "mon_dinner", recipe.id, 4)

  Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
    {:ok, {:tool_calls, [%{id: "c1", name: "skip_meal", args: %{"slot_key" => "mon_dinner", "rationale" => "out"}}]},
     %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
    {:ok, {:message, "Done."}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  ctx = %{household_id: 1, user_id: 1, command: "skip monday", plan_stream_id: plan, week_start: ~D[2026-06-08]}
  {:ok, %State.Applied{}} = Orchestrator.dispatch(:planner_command_run, ctx)

  {:ok, plan_state} = Tore.Handlers.PlanningHandler.load_plan(plan)
  assert plan_state.slots["mon_dinner"].skipped == true
end

test "a failed step leaves the plan stream unwritten (nothing applied)" do
  plan = "plan:2026-06-08-empty"
  Mox.stub(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ -> {:error, :boom} end)

  ctx = %{household_id: 1, user_id: 1, command: "skip monday", plan_stream_id: plan, week_start: ~D[2026-06-08]}
  assert {:error, {:step_failed, :boom}} = Orchestrator.dispatch(:planner_command_run, ctx)

  {:ok, plan_state} = Tore.Handlers.PlanningHandler.load_plan(plan)
  assert plan_state.slots == %{}
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: FAIL — plan not applied (the loop no longer persists), so `skipped` is not set.

- [ ] **Step 3: Implement**

In `lib/tore/harness/orchestrator.ex`:

Add the alias: `alias Tore.Handlers.PlanningHandler`.

In `dispatch/2`, load the working plan and pass it through. Replace the `PlannerAgent.run(...)` line region so the plan is loaded before the loop:

```elixir
with {:ok, state} <- open_run(stream_id, ctx, metadata),
     {:ok, state} <- enter(state, :gathering_context, metadata),
     {:ok, state} <- enter(state, :proposing, metadata),
     {:ok, working_plan} <- PlanningHandler.load_plan(ctx.plan_stream_id),
     {:ok, loop} <- PlannerAgent.run(system_prompt(), ctx.command, agent_ctx(ctx, stream_id, working_plan), []),
     {:ok, state} <- absorb_loop(state, loop, metadata),
     {:ok, state} <- enter(state, :verifying, metadata),
     {:ok, state} <- close(state, loop, ctx, metadata) do
  {:ok, state}
```

Update `agent_ctx/2` to `agent_ctx/3`:

```elixir
defp agent_ctx(ctx, stream_id, working_plan) do
  %{
    plan_id: ctx.plan_stream_id,
    week_start: ctx.week_start,
    household_id: ctx.household_id,
    run_stream_id: stream_id,
    working_plan: working_plan
  }
end
```

In both `close/4` clauses (`:message` and `:capped`), apply events before artifacts:

```elixir
defp close(state, %{result: {:message, _}} = loop, ctx, metadata) do
  plan_diff = PlanDiffBuilder.build(loop.tool_trace, ctx)
  run_summary = RunSummary.from_artifacts([plan_diff], :applied)

  with :ok <- PlanningHandler.apply_events(ctx.plan_stream_id, loop.plan_events),
       {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: plan_diff}, state, metadata),
       {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: run_summary}, state, metadata) do
    apply_command(state.stream_id, %Commands.Commit{}, state, metadata)
  end
end
```

Apply the identical change to the `:capped` clause.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: PASS (including the existing "builds a real PlanDiff" test).

- [ ] **Step 5: Run the full suite to catch regressions from the contract change**

Run: `mix test`
Expected: PASS. If any planner/orchestrator test still passes `@ctx` without `working_plan`, fix it (add `working_plan: %Tore.Planning.State{}` or load via the orchestrator path).

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(harness): Orchestrator loads working plan, applies events once after the loop"
jj new
```

---

# PART 2 — PlanVerifier + repair surfacing

### Task 6: PlanVerifier — pure checks

**Files:**

- Create: `lib/tore/harness/verifier/plan_verifier.ex`
- Test: `test/tore/harness/verifier/plan_verifier_test.exs`

Pure `verify(PlanDiff.t(), ctx) :: :ok | {:fail, code, {:edit_plan, slots}}`. Five checks, first failure wins.

- [ ] **Step 1: Write the failing tests**

Create `test/tore/harness/verifier/plan_verifier_test.exs`:

```elixir
defmodule Tore.Harness.Verifier.PlanVerifierTest do
  use Tore.DataCase, async: false
  alias Tore.Harness.Verifier.PlanVerifier
  alias Tore.Harness.Artifact.PlanDiff
  alias Tore.Planning.{State, Events, Decider}
  alias Tore.Household.Preferences

  defp diff(events), do: %PlanDiff{plan_stream_id: "p", week_start: ~D[2026-06-08], events: events}
  defp ev(slot, type, payload \\ %{}, rationale \\ ["x"]),
    do: %{slot_key: slot, event_type: type, payload: payload, rationale: rationale}
  defp ctx(plan \\ %State{}, prefs \\ %Preferences{}), do: %{plan_state: plan, preferences: prefs}

  test "passes a clean assign" do
    plan = Decider.evolve(%State{}, %Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: 1, servings: 2})
    d = diff([ev("mon_dinner", "RecipeAssigned", %{"recipe_id" => 1, "servings" => 2})])
    assert :ok = PlanVerifier.verify(d, ctx(plan))
  end

  test "fails when a pinned slot was changed" do
    plan = %State{pins: %{"mon_dinner" => true}}
    d = diff([ev("mon_dinner", "MealSkipped")])
    assert {:fail, :slot_pinned, {:edit_plan, ["mon_dinner"]}} = PlanVerifier.verify(d, ctx(plan))
  end

  test "fails when an assigned recipe has no servings" do
    d = diff([ev("mon_dinner", "RecipeAssigned", %{"recipe_id" => 1, "servings" => nil})])
    assert {:fail, :servings_missing, {:edit_plan, ["mon_dinner"]}} = PlanVerifier.verify(d, ctx())
  end

  test "fails when a skip targets a slot not present in the plan" do
    d = diff([ev("fri_dinner", "MealSkipped")])
    assert {:fail, :skip_not_explicit, {:edit_plan, ["fri_dinner"]}} = PlanVerifier.verify(d, ctx(%State{}))
  end

  test "fails when a leftover has no earlier source meal" do
    plan = Decider.evolve(%State{}, %Events.LeftoverMarked{slot_key: "mon_dinner"})
    d = diff([ev("mon_dinner", "LeftoverMarked")])
    # mon is first in the week; no earlier source exists
    assert {:fail, :leftover_no_source, {:edit_plan, ["mon_dinner"]}} =
             PlanVerifier.verify(d, ctx(plan))
  end

  test "passes a leftover with a valid earlier source" do
    plan =
      %State{}
      |> Decider.evolve(%Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: 1, servings: 2})
      |> Decider.evolve(%Events.LeftoverMarked{slot_key: "tue_dinner"})

    d = diff([ev("tue_dinner", "LeftoverMarked")])
    assert :ok = PlanVerifier.verify(d, ctx(plan))
  end

  test "fails when an assigned recipe contains a disliked ingredient" do
    {:ok, r} =
      Tore.Recipes.create(%{
        title: "Peanut Stew", base_servings: 2, instructions: "x",
        ingredients: [%{name: "peanut", quantity: 1, unit: "cup"}]
      })

    prefs = %Preferences{dislikes: ["peanut"]}
    d = diff([ev("mon_dinner", "RecipeAssigned", %{"recipe_id" => r.id, "servings" => 2})])
    plan = Decider.evolve(%State{}, %Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: r.id, servings: 2})

    assert {:fail, :dietary_violation, {:edit_plan, ["mon_dinner"]}} =
             PlanVerifier.verify(d, ctx(plan, prefs))
  end
end
```

(Check the `Tore.Recipes.create` ingredients shape against `test/tore/llm/planner_tools_test.exs` / `Recipes` — adjust the ingredient map keys if `create` expects different keys.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/harness/verifier/plan_verifier_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement `PlanVerifier`**

Create `lib/tore/harness/verifier/plan_verifier.ex`:

```elixir
defmodule Tore.Harness.Verifier.PlanVerifier do
  @moduledoc """
  Deterministic verifier for the planner's PlanDiff. Pure: deterministic reads
  only (recipe ingredients), no writes, no model calls. Returns :ok or the first
  failing check as {:fail, code, {:edit_plan, slots}}.
  """

  alias Tore.Harness.Artifact.PlanDiff

  @day_order ~w(mon tue wed thu fri sat sun)

  @type fail_code ::
          :slot_pinned | :servings_missing | :skip_not_explicit
          | :leftover_no_source | :dietary_violation
  @type repair_action :: {:edit_plan, [String.t()]}
  @type ctx :: %{plan_state: term(), preferences: term()}

  @spec verify(PlanDiff.t(), ctx()) :: :ok | {:fail, fail_code(), repair_action()}
  def verify(%PlanDiff{events: events}, ctx) do
    with :ok <- check_pins(events, ctx.plan_state),
         :ok <- check_servings(events),
         :ok <- check_skips(events, ctx.plan_state),
         :ok <- check_leftovers(events, ctx.plan_state),
         :ok <- check_dietary(events, ctx.preferences) do
      :ok
    end
  end

  defp check_pins(events, plan_state) do
    pinned = Map.keys(plan_state.pins)
    touched = events |> Enum.map(& &1.slot_key) |> Enum.filter(&(&1 in pinned))
    fail_if(touched, :slot_pinned)
  end

  defp check_servings(events) do
    bad =
      events
      |> Enum.filter(&(&1.event_type in ["RecipeAssigned", "ServingsChanged"]))
      |> Enum.reject(&positive_int?(&1.payload["servings"]))
      |> Enum.map(& &1.slot_key)

    fail_if(bad, :servings_missing)
  end

  defp check_skips(events, plan_state) do
    bad =
      events
      |> Enum.filter(&(&1.event_type == "MealSkipped"))
      |> Enum.map(& &1.slot_key)
      |> Enum.reject(&Map.has_key?(plan_state.slots, &1))

    fail_if(bad, :skip_not_explicit)
  end

  defp check_leftovers(events, plan_state) do
    bad =
      events
      |> Enum.filter(&(&1.event_type == "LeftoverMarked"))
      |> Enum.map(& &1.slot_key)
      |> Enum.reject(&has_earlier_source?(&1, plan_state))

    fail_if(bad, :leftover_no_source)
  end

  defp check_dietary(events, prefs) do
    banned = MapSet.new(downcase(prefs.dietary_restrictions ++ prefs.allergies ++ prefs.dislikes))

    bad =
      events
      |> Enum.filter(&(&1.event_type in ["RecipeAssigned", "RecipeSwapped"]))
      |> Enum.filter(fn e -> violates?(e.payload["recipe_id"], banned) end)
      |> Enum.map(& &1.slot_key)

    fail_if(bad, :dietary_violation)
  end

  # --- helpers ---

  defp fail_if([], _code), do: :ok
  defp fail_if(slots, code), do: {:fail, code, {:edit_plan, Enum.uniq(slots)}}

  defp positive_int?(n) when is_integer(n) and n > 0, do: true
  defp positive_int?(_), do: false

  defp has_earlier_source?(slot_key, plan_state) do
    idx = day_index(slot_key)

    Enum.any?(plan_state.slots, fn {k, slot} ->
      day_index(k) < idx and slot.recipe_id != nil and not slot.skipped and not slot.leftover
    end)
  end

  defp day_index(slot_key) do
    day = slot_key |> String.split("_", parts: 2) |> hd()
    Enum.find_index(@day_order, &(&1 == day)) || length(@day_order)
  end

  defp violates?(nil, _banned), do: false

  defp violates?(recipe_id, banned) do
    recipe_id
    |> ingredient_names()
    |> Enum.any?(fn name -> MapSet.member?(banned, name) end)
  end

  defp ingredient_names(recipe_id) do
    Tore.Recipes.get!(recipe_id).recipe_ingredients
    |> Enum.map(&String.downcase(&1.ingredient.name))
  rescue
    Ecto.NoResultsError -> []
  end

  defp downcase(list), do: Enum.map(list, &String.downcase/1)
end
```

(If `RecipeSwapped` payloads don't carry `recipe_id` reliably, the dietary check still works for `RecipeAssigned`; keep `RecipeSwapped` only if `PlanDiffBuilder` populates `recipe_id` for swaps — it does per `event_for("swap_recipe", ...)`.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/harness/verifier/plan_verifier_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): PlanVerifier — five deterministic PlanDiff checks"
jj new
```

---

### Task 7: `repair_action` tuple round-trip in `Run`

**Files:**

- Modify: `lib/tore/harness/run.ex` (`prepare/1`, `rehydrate/1` FailureRecorded clause, helpers)
- Test: `test/tore/harness/run_test.exs`

`{:edit_plan, slots}` can't be JSON-encoded; encode on write, decode via literal map on read.

- [ ] **Step 1: Write the failing test**

Add to `test/tore/harness/run_test.exs`:

```elixir
test "FailureRecorded with an {:edit_plan, slots} repair_action survives a round-trip" do
  sid = Tore.Harness.Run.next_stream_id()
  open = %Tore.Harness.Run.Commands.Open{
    household_id: 1, kind: "planner_command_run", surface: :plan,
    started_by: "user", user_id: 1, input: %{command: "x"}
  }

  {:ok, ev1} = Tore.Harness.Run.decide(open, %State.Draft{stream_id: sid})
  :ok = Tore.Harness.Run.append(sid, ev1, %{})
  {:ok, running} = Tore.Harness.Run.load(sid)
  {:ok, _} = Tore.Harness.Run.decide(%Tore.Harness.Run.Commands.EnterPhase{phase: :proposing}, running)

  fail = %Tore.Harness.Run.Commands.RecordFailure{
    code: :slot_pinned, user_message: nil, repair_action: {:edit_plan, ["mon_dinner", "fri_dinner"]}
  }

  {:ok, evs} = Tore.Harness.Run.decide(fail, %{running | phase: :verifying})
  :ok = Tore.Harness.Run.append(sid, evs, %{})

  assert {:ok, %State.Failed{failure_repair_action: {:edit_plan, ["mon_dinner", "fri_dinner"]}}} =
           Tore.Harness.Run.load(sid)
end
```

(Adjust to the existing test file's helpers/aliases — it already aliases `State`. Use whatever open/append pattern the file already uses if cleaner.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/harness/run_test.exs`
Expected: FAIL — Jason can't encode the tuple (append raises) or it round-trips wrong.

- [ ] **Step 3: Implement encode/decode**

In `lib/tore/harness/run.ex`:

Add a `prepare/1` clause (before the catch-all `defp prepare(event), do: event`):

```elixir
defp prepare(%Events.FailureRecorded{repair_action: {:edit_plan, slots}} = ev),
  do: %Events.FailureRecorded{ev | repair_action: %{"action" => "edit_plan", "slots" => slots}}
```

Replace the `rehydrate/1` FailureRecorded clause so it decodes via a literal map:

```elixir
defp rehydrate(%Events.FailureRecorded{} = event),
  do: %Events.FailureRecorded{
    event
    | code: safe_atom(event.code),
      repair_action: decode_repair(event.repair_action)
  }
```

Add the decoder near the other literal-map helpers:

```elixir
# repair_action round-trips as a map; reconstruct the tuple via a literal map
# (cold-boot safe — no String.to_existing_atom). nil passes through.
defp decode_repair(%{action: "edit_plan", slots: slots}), do: {:edit_plan, slots}
defp decode_repair(%{"action" => "edit_plan", "slots" => slots}), do: {:edit_plan, slots}
defp decode_repair(nil), do: nil
defp decode_repair(other), do: other
```

(The `Jason.decode!(keys: :atoms)` in `deserialize/2` atomizes map keys, so the `%{action: ...}` clause is the live path; keep the string-key clause for safety.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/harness/run_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): round-trip {:edit_plan, slots} repair_action through the event store"
jj new
```

---

### Task 8: Wire the verifier into the Orchestrator gate

**Files:**

- Modify: `lib/tore/harness/orchestrator.ex` (`close/4` clauses)
- Test: `test/tore/harness/orchestrator_test.exs`

The gate sits in `close/4` before `apply_events`. On `:ok`, apply + commit; on `{:fail, code, repair}`, `RecordFailure` (no apply, no commit).

- [ ] **Step 1: Write the failing test**

Add to `test/tore/harness/orchestrator_test.exs`:

```elixir
test "a verifier failure records Failed, applies nothing, commits nothing" do
  {:ok, recipe} = Tore.Recipes.create(%{title: "Pinned dish", recipe_type: :meal, base_servings: 4})
  plan = "plan:2026-06-08-pinned"
  Tore.Handlers.PlanningHandler.assign_recipe(plan, "mon_dinner", recipe.id, 4)
  # Pin the slot so any change to it fails PlanVerifier
  Tore.Handlers.PlanningHandler.pin_slot(plan, "mon_dinner", true)

  Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
    {:ok, {:tool_calls, [%{id: "c1", name: "skip_meal", args: %{"slot_key" => "mon_dinner", "rationale" => "out"}}]},
     %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
    {:ok, {:message, "Done."}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  ctx = %{household_id: 1, user_id: 1, command: "skip monday", plan_stream_id: plan, week_start: ~D[2026-06-08]}

  assert {:ok, %State.Failed{failure_code: :slot_pinned,
                             failure_repair_action: {:edit_plan, ["mon_dinner"]}}} =
           Orchestrator.dispatch(:planner_command_run, ctx)

  # nothing applied: the slot is still assigned, not skipped
  {:ok, plan_state} = Tore.Handlers.PlanningHandler.load_plan(plan)
  refute plan_state.slots["mon_dinner"].skipped

  # no Committed event on the run stream
  sid = latest_run_stream_id()
  {:ok, run} = Tore.Harness.Run.load(sid)
  assert %State.Failed{} = run
end
```

(Confirm `PlanningHandler.pin_slot/3` exists; if the function name differs, use the actual pin API. If pinning isn't exposed via the handler, append `%Events.SlotPinned{slot_key: "mon_dinner", pin: true}` to the plan stream directly via `PlanningHandler.apply_events/2`.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: FAIL — currently the run commits regardless (no verifier yet), so it ends `Applied`.

- [ ] **Step 3: Implement the gate**

In `lib/tore/harness/orchestrator.ex`, add `alias Tore.Harness.Verifier.PlanVerifier`. Rewrite both `close/4` artifact clauses to verify first. Factor the shared body into a helper to avoid duplication:

```elixir
defp close(state, %{result: {:message, _}} = loop, ctx, metadata),
  do: verify_and_finish(state, loop, ctx, metadata)

defp close(state, %{result: {:capped, _}} = loop, ctx, metadata),
  do: verify_and_finish(state, loop, ctx, metadata)

defp close(state, %{result: {:question, q}}, _ctx, metadata),
  do: apply_command(state.stream_id, %Commands.RaiseQuestion{question: q}, state, metadata)

defp verify_and_finish(state, loop, ctx, metadata) do
  plan_diff = PlanDiffBuilder.build(loop.tool_trace, ctx)

  case PlanVerifier.verify(plan_diff, verify_ctx(loop)) do
    :ok ->
      run_summary = RunSummary.from_artifacts([plan_diff], :applied)

      with :ok <- PlanningHandler.apply_events(ctx.plan_stream_id, loop.plan_events),
           {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: plan_diff}, state, metadata),
           {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: run_summary}, state, metadata) do
        apply_command(state.stream_id, %Commands.Commit{}, state, metadata)
      end

    {:fail, code, repair} ->
      apply_command(
        state.stream_id,
        %Commands.RecordFailure{code: code, user_message: nil, repair_action: repair},
        state,
        metadata
      )
  end
end

defp verify_ctx(loop) do
  %{plan_state: loop.working_plan, preferences: Tore.Household.get_preferences()}
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: PASS (verifier-fail test + all earlier happy-path tests).

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(harness): gate the plan apply on PlanVerifier (verify-then-mutate)"
jj new
```

---

### Task 9: Receipt — per-code failure messages + edit link

**Files:**

- Modify: `lib/tore_web/components/receipt_live.ex`
- Modify: `priv/gettext/en/LC_MESSAGES/default.po`, `priv/gettext/sv/LC_MESSAGES/default.po`
- Test: `test/tore_web/components/receipt_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/tore_web/components/receipt_live_test.exs` (locale is pinned to `sv` in setup):

```elixir
defp base_failed(code, repair \\ nil) do
  %State.Failed{
    stream_id: "run-f", household_id: 1, kind: "planner_command_run",
    surface: :plan, started_by: "user", user_id: 1, input: %{command: "x"},
    opened_at: ~U[2026-06-08 12:00:00Z], failed_at: ~U[2026-06-08 12:00:01Z],
    failure_code: code, failure_user_message: nil, failure_repair_action: repair,
    tool_trace: [], artifacts: [],
    model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
  }
end

test "renders a Swedish message for :slot_pinned" do
  html = render_component(ReceiptLive, id: "r", run: base_failed(:slot_pinned))
  assert html =~ "fastlåst" or html =~ "låst"  # adjust to the chosen sv string
end

test "renders an Edit-the-plan link when repair_action is {:edit_plan, slots}" do
  html = render_component(ReceiptLive, id: "r", run: base_failed(:slot_pinned, {:edit_plan, ["mon_dinner"]}))
  assert html =~ "/plan?focus=mon_dinner"
end

test "renders no edit link when repair_action is nil" do
  html = render_component(ReceiptLive, id: "r", run: base_failed(:internal_error, nil))
  refute html =~ "focus="
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: FAIL — generic message, no link.

- [ ] **Step 3: Implement per-code messages + link**

In `lib/tore_web/components/receipt_live.ex`, add clauses to `failure_message/1` (before the catch-all `failure_message(_)`):

```elixir
defp failure_message(:slot_pinned),
  do: gettext("That day is pinned, so Tore left it as it was.")

defp failure_message(:servings_missing),
  do: gettext("A meal was missing servings, so nothing was changed.")

defp failure_message(:skip_not_explicit),
  do: gettext("Tore couldn't tell which day to skip.")

defp failure_message(:leftover_no_source),
  do: gettext("There was no earlier meal to make leftovers from.")

defp failure_message(:dietary_violation),
  do: gettext("A suggested recipe didn't fit your household's needs.")
```

Add a repair-link assign + render. In `update/2`, add `|> assign(:repair_href, repair_href(run))`. Add:

```elixir
defp repair_href(%State.Failed{failure_repair_action: {:edit_plan, slots}}),
  do: "/plan?focus=" <> Enum.join(slots, ",")

defp repair_href(_), do: nil
```

In `render/2`, after the body block, add:

```heex
<a
  :if={@repair_href}
  href={@repair_href}
  class="mt-3 inline-block text-xs font-semibold text-[color:var(--accent)]"
>
  {gettext("Edit the plan")}
</a>
```

(Add `@repair_href` to the default assigns for non-Failed runs — `repair_href/1` returns `nil` for them, so the `:if` hides it.)

- [ ] **Step 4: Extract + translate gettext strings**

Run: `mix gettext.extract && mix gettext.merge priv/gettext`
Then edit `priv/gettext/sv/LC_MESSAGES/default.po`: fill the Swedish `msgstr` for each new `msgid` (`"That day is pinned…"`, `"A meal was missing servings…"`, `"Tore couldn't tell which day to skip."`, `"There was no earlier meal to make leftovers from."`, `"A suggested recipe didn't fit your household's needs."`, `"Edit the plan"`) and **delete the `, fuzzy` flag line** above each filled entry (the fuzzy trap — gettext ignores fuzzy at runtime). Suggested sv strings:

- "That day is pinned, so Tore left it as it was." → "Den dagen är fastlåst, så Tore lät den vara."
- "A meal was missing servings, so nothing was changed." → "En måltid saknade portioner, så inget ändrades."
- "Tore couldn't tell which day to skip." → "Tore kunde inte avgöra vilken dag som skulle hoppas över."
- "There was no earlier meal to make leftovers from." → "Det fanns ingen tidigare måltid att göra rester av."
- "A suggested recipe didn't fit your household's needs." → "Ett föreslaget recept passade inte hushållets behov."
- "Edit the plan" → "Redigera planen"

(Adjust the Task-9 Step-1 assertion to match the chosen sv string for `:slot_pinned`, e.g. `assert html =~ "fastlåst"`.)

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(web): receipt renders per-code verifier failures + Edit-the-plan link (en/sv)"
jj new
```

---

### Task 10: Planner slot focus from the `focus` param

**Files:**

- Modify: `lib/tore_web/live/planner_live.ex` (add `handle_params/3`, thread `focused_slots` into `day_row`)
- Test: `test/tore_web/live/planner_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/tore_web/live/planner_live_test.exs`. The file already has `setup` providing `%{user: user}` and a `defp authed(conn, user)` helper; reuse them:

```elixir
test "focus param highlights the named slots", %{conn: conn, user: user} do
  conn = authed(conn, user)
  {:ok, _lv, html} = live(conn, "/plan?focus=mon_dinner")
  assert html =~ ~s(id="slot-mon_dinner")  # anchor present on every row
  assert html =~ "ring-2"                   # highlight only appears when focused
end

test "no focus param highlights nothing", %{conn: conn, user: user} do
  conn = authed(conn, user)
  {:ok, _lv, html} = live(conn, "/plan")
  refute html =~ "ring-2"
end
```

(Note `id="slot-<key>"` is added to every day_row in Step 3, so the first test
asserts the highlight class `ring-2`, not the id, to distinguish focused from
unfocused. The second test asserts the highlight class is absent.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: FAIL — no id/highlight.

- [ ] **Step 3: Implement**

In `lib/tore_web/live/planner_live.ex`:

In `mount/3`, add `focused_slots: MapSet.new()` to the `assign(socket, ...)` call.

Add a `handle_params/3` (after `mount/3`):

```elixir
def handle_params(params, _uri, socket) do
  slots =
    case params["focus"] do
      f when is_binary(f) and f != "" -> f |> String.split(",", trim: true) |> MapSet.new()
      _ -> MapSet.new()
    end

  {:noreply, assign(socket, focused_slots: slots)}
end
```

Pass `focused_slots` into the `day_row` call in the template:

```heex
<.day_row
  :for={{day, i} <- Enum.with_index(@days)}
  day={day}
  date={Date.add(@week_start, i)}
  today={@today}
  slot_key={"#{day}_dinner"}
  plan_state={@plan_state}
  recipes={@recipes}
  days={@days}
  focused={MapSet.member?(@focused_slots, "#{day}_dinner")}
/>
```

In `day_row/1`, add the id + highlight to the `<li>`:

```heex
<li
  id={"slot-#{@slot_key}"}
  class={[
    "transition-colors",
    @slot && @slot.skipped && "opacity-50",
    @focused && "ring-2 ring-[color:var(--accent)] rounded-xl"
  ]}
>
```

`day_row/1` declares its attrs explicitly (`attr :day, ...` etc. above the function), so you **must** add a new declaration with the others:

```elixir
attr :focused, :boolean, default: false
```

Otherwise Phoenix raises on the undeclared `focused` assign.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(web): planner highlights slots from a focus query param"
jj new
```

---

### Task 11: Full-suite green + CHANGELOG

**Files:**

- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run the entire suite at a fixed seed and twice random**

Run: `mix test --seed 0` then `mix test` (twice).
Expected: 0 failures all three runs.

- [ ] **Step 2: Append to CHANGELOG**

Under `[Unreleased]`, add entries:

```markdown
### Added
- Pure planner loop: action tools propose plan changes against an in-memory
  working state; the Orchestrator applies them once after the loop
  (verify-then-mutate).
- `PlanVerifier` — deterministic gate for the planner's PlanDiff (pinned slots,
  servings, explicit skips, leftover sources, dietary/allergy/dislike). A
  failure records the run as Failed atomically; the plan stream is never
  written. Repeat-window check deferred (needs a repeat_window preference).
- Receipt repair state: per-code Swedish/English failure messages + an
  "Edit the plan" link that deep-links the planner to the offending slots.
- Planner slot focus via a `focus` query param (highlight + anchor).
```

- [ ] **Step 3: Commit**

```bash
jj describe -m "docs: changelog — pure planner loop + PlanVerifier"
jj new
```

---

## Final review & finish

After Task 11, dispatch a final code review over the whole change, then use **superpowers:finishing-a-development-branch** to set `master` to the work tip and `jj git push -b master`.

**Manual smoke (user-run):** because Mox returns clean values, several past bugs only surfaced under live OpenRouter. After the suite is green, the user runs a real planner command (one that should pass the verifier, and one that should trip `:slot_pinned`) to confirm the gate, the apply, and the receipt repair state end-to-end. Do not run smoke yourself (no API key access).
