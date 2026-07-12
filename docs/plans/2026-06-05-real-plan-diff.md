# Real PlanDiff from tool outcomes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder `PlanDiff` with a real diff reconstructed from the planner's successful tool calls, and fix `swap_recipe` to be a true atomic swap.

**Architecture:** A new pure module `Tore.Harness.PlanDiffBuilder` reconstructs `PlanDiff` event entries from `PlannerAgent`'s `tool_trace` (joining tool-call args to their results by `tool_call_id`, keeping only successful action calls). The Orchestrator calls it in place of `build_plan_diff/1`. Two new PlanDiff event types (`RecipeSwapped`, `ServingsChanged`) extend the rollup; RunSummary wording is humanized. Action tools gain a required `rationale` arg and recipe-placing tools return a `label`. `swap_recipe` becomes atomic via a new `PlanningHandler.swap_slots/3`.

**Tech Stack:** Elixir, ExUnit, Mox (`Tore.MockLLM`), Jason. VCS is **jj (Jujutsu), never git**.

**Spec:** `docs/specs/2026-06-05-real-plan-diff-design.md`

**Baseline:** Pre-existing test floor is 5 failures in `Tore.Groceries.*` / `GroceriesHandlerTest` (Mox global-mode race), unrelated to this work. "No new failures" = that floor unchanged.

**Per-task VCS discipline:** At the start of each task run `jj st`; if the working copy is not clean/empty, run `jj new` before editing. Each task ends with `jj describe -m "<msg>"` then `jj new`.

---

## Reference: shapes you will rely on

- `PlannerAgent` trace entries (already implemented):
  - tool_calls: `%{step_index: i, step_kind: :tool_calls, payload: %{calls: <JSON string>}}` where the JSON decodes to a list of `%{"id" => ..., "name" => ..., "args" => %{...}}`.
  - tool_result: `%{step_index: i, step_kind: :tool_result, payload: %{tool_call_id: id, name: name, result: result_map}}`.
  - A failed action result is `%{error: "..."}` (atom-key `:error`); a success is e.g. `%{ok: true}` or `%{ok: true, label: "..."}`.
- `Tore.Harness.Artifact.PlanDiff` event_entry: `%{slot_key: String, event_type: String, payload: map, rationale: [String]}`.
- `Tore.Recipes.get!(id)` returns a `%Recipe{title: ...}` (raises on missing id — use a safe wrapper).
- Planning slot map: `%{recipe_id:, servings:, skipped:, leftover:}`.
- `Tore.Handlers.PlanningHandler` ops: `load_plan/1`, `assign_recipe/4`, `remove_recipe/2`, `set_servings/3`, `skip_meal/2`, `mark_leftover/2`. Pattern for batched multi-event ops: `assign_with_leftovers/5` (load once → decide+evolve sequence → `EventStore.append` once → `PubSub.broadcast(@pubsub, @topic, {:events, events})`).
- Planning `Decider`/`Commands`/`Events` live in `lib/tore/planning/`. `AssignRecipe`, `RemoveRecipe` commands exist.

---

## Task 1: PlanDiff rollup gains RecipeSwapped + ServingsChanged

**Files:**
- Modify: `lib/tore/harness/artifact/plan_diff.ex`
- Test: `test/tore/harness/artifact/plan_diff_test.exs`

- [ ] **Step 1: Add failing tests for the two new rollup mappings**

Append to `test/tore/harness/artifact/plan_diff_test.exs` (inside the existing `describe "summarise/1"` block, or at top level if none — match the file's existing style):

```elixir
  test "summarise/1 maps RecipeSwapped to :swapped" do
    diff = %PlanDiff{
      plan_stream_id: "p", week_start: ~D[2026-06-01],
      events: [%{slot_key: "sun_dinner", event_type: "RecipeSwapped",
                 payload: %{"from_slot_key" => "fri_dinner", "to_slot_key" => "sun_dinner"},
                 rationale: ["because"]}]
    }
    assert [%{slot_key: "sun_dinner", change: :swapped}] = PlanDiff.summarise(diff)
  end

  test "summarise/1 maps ServingsChanged to :servings" do
    diff = %PlanDiff{
      plan_stream_id: "p", week_start: ~D[2026-06-01],
      events: [%{slot_key: "mon_dinner", event_type: "ServingsChanged",
                 payload: %{"servings" => 6}, rationale: ["more guests"]}]
    }
    assert [%{slot_key: "mon_dinner", change: :servings}] = PlanDiff.summarise(diff)
  end

  test "summarise/1 maps a lone RecipeAssigned to :added and lone RecipeRemoved to :removed" do
    diff = %PlanDiff{
      plan_stream_id: "p", week_start: ~D[2026-06-01],
      events: [
        %{slot_key: "mon_dinner", event_type: "RecipeAssigned", payload: %{}, rationale: ["x"]},
        %{slot_key: "tue_dinner", event_type: "RecipeRemoved", payload: %{}, rationale: ["y"]}
      ]
    }
    rollup = PlanDiff.summarise(diff)
    assert Enum.find(rollup, &(&1.slot_key == "mon_dinner")).change == :added
    assert Enum.find(rollup, &(&1.slot_key == "tue_dinner")).change == :removed
  end
```

Ensure `alias Tore.Harness.Artifact.PlanDiff` is present at the top of the test file (it is in the existing file).

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore/harness/artifact/plan_diff_test.exs`
Expected: the RecipeSwapped/ServingsChanged tests FAIL (currently classified `:added` by the `true ->` fallback), or the swap test passes only by the old derived branch. The lone-assign/lone-remove test should pass already.

- [ ] **Step 3: Rewrite `rollup_for/2`'s change classification**

In `lib/tore/harness/artifact/plan_diff.ex`, replace the `cond do ... end` block inside `rollup_for/2` with a direct per-event-type mapping. The current code is:

```elixir
    change =
      cond do
        "RecipeRemoved" in types and "RecipeAssigned" in types -> :swapped
        "RecipeAssigned" in types -> :added
        "MealSkipped" in types -> :skipped
        "LeftoverMarked" in types -> :leftover
        "RecipeRemoved" in types -> :removed
        true -> :added
      end
```

Replace with:

```elixir
    change =
      cond do
        "RecipeSwapped" in types -> :swapped
        "RecipeAssigned" in types -> :added
        "MealSkipped" in types -> :skipped
        "LeftoverMarked" in types -> :leftover
        "RecipeRemoved" in types -> :removed
        "ServingsChanged" in types -> :servings
        true -> :added
      end
```

- [ ] **Step 4: Update the `rollup_change` type**

Find the typespec line:

```elixir
  @type rollup_change :: :added | :swapped | :skipped | :leftover | :removed
```

Replace with:

```elixir
  @type rollup_change :: :added | :swapped | :skipped | :leftover | :removed | :servings
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/tore/harness/artifact/plan_diff_test.exs`
Expected: PASS (all, including the new three).

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(harness): PlanDiff rollup maps RecipeSwapped + ServingsChanged"
jj new
```

---

## Task 2: RunSummary humanized change wording

**Files:**
- Modify: `lib/tore/harness/artifact/run_summary.ex`
- Modify: `lib/tore/harness/artifact/plan_diff.ex` (its local `text_from_counts/1`, for consistency)
- Test: `test/tore/harness/artifact/run_summary_test.exs`

- [ ] **Step 1: Read the current text_from_counts in both files**

Run: `grep -n "text_from_counts\|defp.*counts" lib/tore/harness/artifact/run_summary.ex lib/tore/harness/artifact/plan_diff.ex`
Note the exact current implementation in each (both currently do `"#{n} #{change}"`).

- [ ] **Step 2: Add a failing test for the wording**

Append to `test/tore/harness/artifact/run_summary_test.exs`:

```elixir
  test "from_artifacts text_fallback uses human wording per change type" do
    diff = %Tore.Harness.Artifact.PlanDiff{
      plan_stream_id: "p", week_start: ~D[2026-06-01],
      events: [
        %{slot_key: "mon_dinner", event_type: "RecipeAssigned", payload: %{}, rationale: ["a"]},
        %{slot_key: "tue_dinner", event_type: "ServingsChanged", payload: %{"servings" => 6}, rationale: ["b"]}
      ]
    }
    summary = Tore.Harness.Artifact.RunSummary.from_artifacts([diff], :applied)
    text = Tore.Harness.Artifact.RunSummary.summary(summary).text_fallback
    assert text =~ "1 added"
    assert text =~ "1 servings adjusted"
    refute text =~ "1 servings,"
  end
```

(If `run_summary_test.exs` lacks a helper to build counts, this end-to-end shape via `from_artifacts` is the most robust assertion. Adjust the alias style to match the file.)

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/tore/harness/artifact/run_summary_test.exs`
Expected: FAIL — current output is "1 servings" not "1 servings adjusted".

- [ ] **Step 4: Add a `change_label/1` helper and use it in RunSummary**

In `lib/tore/harness/artifact/run_summary.ex`, locate `text_from_counts/1` (the helper that joins `counts` into prose). Replace its per-entry formatting so each entry uses a label function. Concretely, change the mapping from `"#{n} #{change}"` to `"#{n} #{change_label(change)}"` and add:

```elixir
  defp change_label(:added), do: "added"
  defp change_label(:swapped), do: "swapped"
  defp change_label(:skipped), do: "skipped"
  defp change_label(:leftover), do: "leftovers"
  defp change_label(:removed), do: "removed"
  defp change_label(:servings), do: "servings adjusted"
  defp change_label(other), do: to_string(other)
```

(Counts keys may be atoms or strings depending on how `from_artifacts` builds them. If `text_from_counts` receives string keys, make `change_label/1` accept the string form too, or normalize with `to_string`/`String.to_existing_atom` at the call site — match whatever `from_artifacts` actually produces; verify by reading it in Step 1.)

- [ ] **Step 5: Mirror the wording in PlanDiff's local helper**

In `lib/tore/harness/artifact/plan_diff.ex`, apply the same `change_label/1` treatment to its local `text_from_counts/1` so a directly-summarised PlanDiff reads consistently. Add the identical private `change_label/1` clauses there. Do NOT extract a shared module (avoid a single-use abstraction; the duplication is two tiny private helpers).

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/tore/harness/artifact/run_summary_test.exs test/tore/harness/artifact/plan_diff_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(harness): humanize RunSummary/PlanDiff change wording"
jj new
```

---

## Task 3: PlanDiffBuilder — reconstruct diff from tool trace

**Files:**
- Create: `lib/tore/harness/plan_diff_builder.ex`
- Test: `test/tore/harness/plan_diff_builder_test.exs`

- [ ] **Step 1: Write the failing test file**

Create `test/tore/harness/plan_diff_builder_test.exs`:

```elixir
defmodule Tore.Harness.PlanDiffBuilderTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.PlanDiffBuilder
  alias Tore.Harness.Artifact.PlanDiff

  @ctx %{plan_stream_id: "plan:2026-06-01", week_start: ~D[2026-06-01]}

  # Build a tool_calls trace entry from a list of {id, name, args}.
  defp calls_entry(idx, calls) do
    encoded =
      Jason.encode!(
        Enum.map(calls, fn {id, name, args} -> %{id: id, name: name, args: args} end)
      )

    %{step_index: idx, step_kind: :tool_calls, payload: %{calls: encoded}}
  end

  defp result_entry(idx, id, name, result) do
    %{step_index: idx, step_kind: :tool_result,
      payload: %{tool_call_id: id, name: name, result: result}}
  end

  test "skip_meal success becomes one MealSkipped event with rationale" do
    trace = [
      calls_entry(0, [{"c1", "skip_meal", %{"slot_key" => "mon_dinner", "rationale" => "busy"}}]),
      result_entry(1, "c1", "skip_meal", %{ok: true})
    ]

    diff = PlanDiffBuilder.build(trace, @ctx)
    assert %PlanDiff{plan_stream_id: "plan:2026-06-01", week_start: ~D[2026-06-01]} = diff
    assert [%{slot_key: "mon_dinner", event_type: "MealSkipped", payload: %{}, rationale: ["busy"]}] =
             diff.events
  end

  test "assign_recipe carries recipe_id, servings, label into payload" do
    trace = [
      calls_entry(0, [{"c1", "assign_recipe",
        %{"slot_key" => "mon_dinner", "recipe_id" => 7, "servings" => 4, "rationale" => "quick"}}]),
      result_entry(1, "c1", "assign_recipe", %{ok: true, label: "Roast chicken"})
    ]

    [event] = PlanDiffBuilder.build(trace, @ctx).events
    assert event.event_type == "RecipeAssigned"
    assert event.slot_key == "mon_dinner"
    assert event.payload["recipe_id"] == 7
    assert event.payload["servings"] == 4
    assert event.payload["label"] == "Roast chicken"
    assert event.rationale == ["quick"]
  end

  test "swap_recipe uses to_slot_key and records both slots + label" do
    trace = [
      calls_entry(0, [{"c1", "swap_recipe",
        %{"from_slot_key" => "fri_dinner", "to_slot_key" => "sun_dinner", "rationale" => "prefer weekend"}}]),
      result_entry(1, "c1", "swap_recipe", %{ok: true, label: "Lamb", recipe_id: 9})
    ]

    [event] = PlanDiffBuilder.build(trace, @ctx).events
    assert event.event_type == "RecipeSwapped"
    assert event.slot_key == "sun_dinner"
    assert event.payload["from_slot_key"] == "fri_dinner"
    assert event.payload["to_slot_key"] == "sun_dinner"
    assert event.payload["recipe_id"] == 9
    assert event.payload["label"] == "Lamb"
  end

  test "set_servings becomes ServingsChanged" do
    trace = [
      calls_entry(0, [{"c1", "set_servings", %{"slot_key" => "mon_dinner", "servings" => 6, "rationale" => "guests"}}]),
      result_entry(1, "c1", "set_servings", %{ok: true})
    ]

    [event] = PlanDiffBuilder.build(trace, @ctx).events
    assert event.event_type == "ServingsChanged"
    assert event.payload["servings"] == 6
  end

  test "failed result is excluded" do
    trace = [
      calls_entry(0, [{"c1", "skip_meal", %{"slot_key" => "mon_dinner", "rationale" => "x"}}]),
      result_entry(1, "c1", "skip_meal", %{error: "slot_empty"})
    ]

    assert PlanDiffBuilder.build(trace, @ctx).events == []
  end

  test "action_cap_reached result is excluded" do
    trace = [
      calls_entry(0, [{"c1", "remove_recipe", %{"slot_key" => "mon_dinner", "rationale" => "x"}}]),
      result_entry(1, "c1", "remove_recipe", %{error: "action_cap_reached"})
    ]

    assert PlanDiffBuilder.build(trace, @ctx).events == []
  end

  test "read tool and ask_user results are excluded" do
    trace = [
      calls_entry(0, [
        {"c1", "search_recipes", %{"query" => "x"}},
        {"c2", "ask_user", %{"question" => "which?"}}
      ]),
      result_entry(1, "c1", "search_recipes", %{ok: true, results: []}),
      result_entry(2, "c2", "ask_user", %{ok: true, question: "which?"})
    ]

    assert PlanDiffBuilder.build(trace, @ctx).events == []
  end

  test "missing rationale degrades to empty list" do
    trace = [
      calls_entry(0, [{"c1", "skip_meal", %{"slot_key" => "mon_dinner"}}]),
      result_entry(1, "c1", "skip_meal", %{ok: true})
    ]

    [event] = PlanDiffBuilder.build(trace, @ctx).events
    assert event.rationale == []
  end

  test "multiple successful actions across round trips, in trace order" do
    trace = [
      calls_entry(0, [{"c1", "skip_meal", %{"slot_key" => "mon_dinner", "rationale" => "a"}}]),
      result_entry(1, "c1", "skip_meal", %{ok: true}),
      calls_entry(2, [{"c2", "remove_recipe", %{"slot_key" => "tue_dinner", "rationale" => "b"}}]),
      result_entry(3, "c2", "remove_recipe", %{ok: true})
    ]

    events = PlanDiffBuilder.build(trace, @ctx).events
    assert Enum.map(events, & &1.event_type) == ["MealSkipped", "RecipeRemoved"]
  end

  test "empty trace yields empty events" do
    assert PlanDiffBuilder.build([], @ctx).events == []
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/harness/plan_diff_builder_test.exs`
Expected: FAIL — `Tore.Harness.PlanDiffBuilder` is undefined.

- [ ] **Step 3: Write the module**

Create `lib/tore/harness/plan_diff_builder.ex`:

```elixir
defmodule Tore.Harness.PlanDiffBuilder do
  @moduledoc """
  Pure: reconstructs a `PlanDiff` from a PlannerAgent tool trace by joining
  tool-call args to their results and keeping only successful action calls.
  """

  alias Tore.Harness.Artifact.PlanDiff

  @action_tools ~w(assign_recipe swap_recipe skip_meal mark_leftover set_servings remove_recipe)

  @spec build([map()], map()) :: PlanDiff.t()
  def build(tool_trace, ctx) do
    calls = index_calls(tool_trace)

    events =
      tool_trace
      |> Enum.filter(&(&1.step_kind == :tool_result))
      |> Enum.flat_map(fn entry -> event_from_result(entry, calls) end)

    %PlanDiff{
      plan_stream_id: ctx.plan_stream_id,
      week_start: ctx.week_start,
      events: events
    }
  end

  defp index_calls(tool_trace) do
    tool_trace
    |> Enum.filter(&(&1.step_kind == :tool_calls))
    |> Enum.flat_map(fn entry ->
      entry.payload
      |> fetch(:calls)
      |> Jason.decode!()
    end)
    |> Map.new(fn call -> {call["id"], %{name: call["name"], args: call["args"]}} end)
  end

  defp event_from_result(entry, calls) do
    id = fetch(entry.payload, :tool_call_id)
    result = fetch(entry.payload, :result)

    with %{name: name, args: args} <- Map.get(calls, id),
         true <- name in @action_tools,
         true <- success?(result),
         entry when is_map(entry) <- event_for(name, args, result) do
      [entry]
    else
      _ -> []
    end
  end

  defp event_for("assign_recipe", args, result) do
    event(args, "slot_key", "RecipeAssigned", %{
      "recipe_id" => args["recipe_id"],
      "servings" => args["servings"],
      "label" => label_of(result)
    })
  end

  defp event_for("swap_recipe", args, result) do
    event(args, "to_slot_key", "RecipeSwapped", %{
      "from_slot_key" => args["from_slot_key"],
      "to_slot_key" => args["to_slot_key"],
      "recipe_id" => fetch(result, :recipe_id),
      "label" => label_of(result)
    })
  end

  defp event_for("skip_meal", args, _result),
    do: event(args, "slot_key", "MealSkipped", %{})

  defp event_for("mark_leftover", args, _result),
    do: event(args, "slot_key", "LeftoverMarked", %{})

  defp event_for("remove_recipe", args, _result),
    do: event(args, "slot_key", "RecipeRemoved", %{})

  defp event_for("set_servings", args, _result),
    do: event(args, "slot_key", "ServingsChanged", %{"servings" => args["servings"]})

  defp event(args, slot_arg, event_type, payload) do
    %{
      slot_key: args[slot_arg],
      event_type: event_type,
      payload: payload,
      rationale: rationale_of(args)
    }
  end

  defp success?(result) when is_map(result),
    do: not (Map.has_key?(result, :error) or Map.has_key?(result, "error"))

  defp success?(_), do: false

  defp rationale_of(args) do
    case args["rationale"] do
      r when is_binary(r) and r != "" -> [r]
      _ -> []
    end
  end

  defp label_of(result), do: fetch(result, :label)

  # Tolerant key fetch: trace payloads use atom keys in-memory, but results
  # may carry atom or string keys depending on the tool.
  defp fetch(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp fetch(_, _), do: nil
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/harness/plan_diff_builder_test.exs`
Expected: PASS (all 10 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): PlanDiffBuilder reconstructs diff from tool trace"
jj new
```

---

## Task 4: Orchestrator uses PlanDiffBuilder

**Files:**
- Modify: `lib/tore/harness/orchestrator.ex`
- Test: `test/tore/harness/orchestrator_test.exs`

- [ ] **Step 1: Add a failing test that a skip run yields a real MealSkipped diff**

Read the existing `test/tore/harness/orchestrator_test.exs` first to match its setup (it uses `Tore.MockLLM` via Mox and asserts on the final `State`). Add a test that mocks a single `skip_meal` tool call + a final message, dispatches, loads the run, and asserts the PlanDiff artifact has a `MealSkipped` event for the right slot (not the `"run"` placeholder):

```elixir
  test "dispatch builds a real PlanDiff from the planner's skip_meal call" do
    stub(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, tools, _opts ->
      if tools == [] do
        {:ok, {:message, "Done."}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      else
        {:ok,
         {:tool_calls,
          [%{id: "c1", name: "skip_meal",
             args: %{"slot_key" => "mon_dinner", "rationale" => "busy night"}}]},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end
    end)

    ctx = %{
      household_id: 1, user_id: 1, command: "skip monday",
      plan_stream_id: "plan:2026-06-01", week_start: ~D[2026-06-01]
    }

    {:ok, state} = Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)

    plan_diff = Enum.find(state.artifacts, &match?(%Tore.Harness.Artifact.PlanDiff{}, &1))
    assert [%{slot_key: "mon_dinner", event_type: "MealSkipped", rationale: ["busy night"]}] =
             plan_diff.events
    refute Enum.any?(plan_diff.events, &(&1.slot_key == "run"))
  end
```

Note: this test runs the real planner loop with a stubbed LLM. The `skip_meal` tool will actually call `PlanningHandler.skip_meal/2` against `plan:2026-06-01`; that requires the plan stream to tolerate skipping an empty/non-existent slot. If `skip_meal` returns `{:error, :slot_empty}` for an unplanned slot, the tool result will be an error and the diff will be empty — in that case, the test setup must first assign a recipe to `mon_dinner` (use `Tore.Handlers.PlanningHandler.assign_recipe("plan:2026-06-01", "mon_dinner", recipe.id, 4)` in setup, creating a recipe via `Tore.Recipes.create/1`). Check the planning Decider's `SkipMeal` clause: if it requires the slot to exist, seed it. Match the existing orchestrator test's data setup conventions.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: FAIL — current `build_plan_diff/1` emits the `"run"` placeholder, so the assertion on `slot_key: "mon_dinner"` fails.

- [ ] **Step 3: Replace build_plan_diff with PlanDiffBuilder**

In `lib/tore/harness/orchestrator.ex`:

1. Add alias: `alias Tore.Harness.PlanDiffBuilder` (near the other aliases).
2. `close/4` already has signature `close(state, loop, ctx, metadata)` — `loop` is in scope. `loop.tool_trace` is the raw PlannerAgent trace, which exactly matches PlanDiffBuilder's contract (entries with `step_kind` and `payload: %{calls: ...}` / `payload: %{tool_call_id, name, result}`). In both the `{:message, _}` and `{:capped, _}` branches of `close/4`, replace the placeholder call `build_plan_diff(ctx)` with `PlanDiffBuilder.build(loop.tool_trace, ctx)`.

   (Do NOT use `state.tool_trace`: the evolved trace from `step_entry/1` carries the same `payload` but going through `loop.tool_trace` keeps the builder's input identical to what it's unit-tested against. The `{:message, _}` branch matches `%{result: {:message, _}}` — confirm you still have the full `loop` map bound, not just the destructured result; if the branch head destructures `loop`, widen it to bind `loop` as well, e.g. `defp close(state, %{result: {:message, _}} = loop, ctx, metadata)`.)

3. Delete the `build_plan_diff/1` private function entirely.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: PASS.

- [ ] **Step 5: Confirm no other caller of build_plan_diff remains**

Run: `grep -rn "build_plan_diff" lib/ test/`
Expected: empty.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(harness): Orchestrator builds real PlanDiff via PlanDiffBuilder"
jj new
```

---

## Task 5: PlanningHandler.swap_slots/3 — atomic swap

**Files:**
- Modify: `lib/tore/handlers/planning_handler.ex`
- Test: `test/tore/handlers/planning_handler_test.exs`

- [ ] **Step 1: Add failing tests for swap_slots/3**

Read `test/tore/handlers/planning_handler_test.exs` for setup conventions (recipe creation, plan_id helper). Add:

```elixir
  describe "swap_slots/3" do
    setup do
      {:ok, a} = Tore.Recipes.create(%{title: "Alpha", recipe_type: :meal, base_servings: 4})
      {:ok, b} = Tore.Recipes.create(%{title: "Beta", recipe_type: :meal, base_servings: 2})
      %{a: a, b: b}
    end

    test "swaps two occupied slots, preserving both recipes and their servings", %{a: a, b: b} do
      plan = "plan:swap-1"
      PlanningHandler.assign_recipe(plan, "fri_dinner", a.id, 4)
      PlanningHandler.assign_recipe(plan, "sun_dinner", b.id, 2)

      assert {:ok, _events} = PlanningHandler.swap_slots(plan, "fri_dinner", "sun_dinner")

      {:ok, state} = PlanningHandler.load_plan(plan)
      assert state.slots["fri_dinner"].recipe_id == b.id
      assert state.slots["fri_dinner"].servings == 2
      assert state.slots["sun_dinner"].recipe_id == a.id
      assert state.slots["sun_dinner"].servings == 4
    end

    test "one slot empty: moves the recipe and clears the source", %{a: a} do
      plan = "plan:swap-2"
      PlanningHandler.assign_recipe(plan, "fri_dinner", a.id, 4)

      assert {:ok, _events} = PlanningHandler.swap_slots(plan, "fri_dinner", "sun_dinner")

      {:ok, state} = PlanningHandler.load_plan(plan)
      assert state.slots["sun_dinner"].recipe_id == a.id
      refute Map.has_key?(state.slots, "fri_dinner")
    end

    test "both slots empty returns {:error, :nothing_to_swap}" do
      plan = "plan:swap-3"
      assert {:error, :nothing_to_swap} = PlanningHandler.swap_slots(plan, "fri_dinner", "sun_dinner")
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/handlers/planning_handler_test.exs`
Expected: FAIL — `swap_slots/3` undefined.

- [ ] **Step 3: Implement swap_slots/3**

In `lib/tore/handlers/planning_handler.ex`, add (following the `assign_with_leftovers/5` batched pattern — load once, build commands, decide+evolve, append all, broadcast once). `Commands` and `Decider` are already aliased at the top of the module.

```elixir
  @doc """
  Atomically swaps the recipes (and their servings) between two slots in one
  append. If one slot is empty, the occupied recipe moves to the empty slot and
  the source is cleared. If both are empty, returns {:error, :nothing_to_swap}.
  """
  def swap_slots(plan_id, slot_a, slot_b) do
    with {:ok, state} <- EventStore.load(plan_id, Decider) do
      a = Map.get(state.slots, slot_a)
      b = Map.get(state.slots, slot_b)

      case swap_commands(slot_a, a, slot_b, b) do
        [] ->
          {:error, :nothing_to_swap}

        commands ->
          {events, _final} =
            Enum.reduce(commands, {[], state}, fn cmd, {acc, st} ->
              {:ok, evts} = Decider.decide(cmd, st)
              st2 = Enum.reduce(evts, st, &Decider.evolve(&2, &1))
              {acc ++ evts, st2}
            end)

          with :ok <- EventStore.append(plan_id, events) do
            PubSub.broadcast(@pubsub, @topic, {:events, events})
            {:ok, events}
          end
      end
    end
  end

  # Build the command sequence for a swap. Reads both slots' values first
  # (captured in `a`/`b` before any command runs) so neither clobbers the other.
  defp swap_commands(slot_a, nil, slot_b, nil), do: []

  defp swap_commands(slot_a, a, slot_b, nil) do
    [
      %Commands.AssignRecipe{slot_key: slot_b, recipe_id: a.recipe_id, servings: a.servings},
      %Commands.RemoveRecipe{slot_key: slot_a}
    ]
  end

  defp swap_commands(slot_a, nil, slot_b, b) do
    [
      %Commands.AssignRecipe{slot_key: slot_a, recipe_id: b.recipe_id, servings: b.servings},
      %Commands.RemoveRecipe{slot_key: slot_b}
    ]
  end

  defp swap_commands(slot_a, a, slot_b, b) do
    [
      %Commands.AssignRecipe{slot_key: slot_a, recipe_id: b.recipe_id, servings: b.servings},
      %Commands.AssignRecipe{slot_key: slot_b, recipe_id: a.recipe_id, servings: a.servings}
    ]
  end
```

Note: a slot with `recipe_id: nil` (e.g. skipped-but-no-recipe) should be treated as empty. If the slot map can exist with `recipe_id: nil`, guard `swap_commands` on `a.recipe_id`/`b.recipe_id` being non-nil instead of the slot struct being nil. Inspect the slot shape: `Map.get(state.slots, key)` returns `nil` for an unassigned slot, or a `%{recipe_id: ...}` map. Add a normalizing step at the top of `swap_slots/3`: `a = present(Map.get(state.slots, slot_a))` where `defp present(%{recipe_id: rid} = s) when not is_nil(rid), do: s; defp present(_), do: nil`. Use `present/1` so a recipe-less slot counts as empty.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/handlers/planning_handler_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(planning): swap_slots/3 — atomic recipe swap, no data loss"
jj new
```

---

## Task 6: swap_recipe tool uses swap_slots + returns label

**Files:**
- Modify: `lib/tore/llm/planner_tools.ex`
- Test: `test/tore/llm/planner_tools_test.exs`

- [ ] **Step 1: Add failing tests for atomic swap + label**

Read `test/tore/llm/planner_tools_test.exs` for the existing swap test and conventions (it builds a plan, calls the tool's `run`, asserts plan state). Add/replace the swap test:

```elixir
  test "swap_recipe performs a true swap with no data loss" do
    {:ok, a} = Tore.Recipes.create(%{title: "Alpha", recipe_type: :meal, base_servings: 4})
    {:ok, b} = Tore.Recipes.create(%{title: "Beta", recipe_type: :meal, base_servings: 2})
    plan = "plan:tool-swap-1"
    PlanningHandler.assign_recipe(plan, "fri_dinner", a.id, 4)
    PlanningHandler.assign_recipe(plan, "sun_dinner", b.id, 2)

    tool = Enum.find(PlannerTools.all(), &(&1.name == "swap_recipe"))

    assert {:ok, result} =
             tool.run.(%{"from_slot_key" => "fri_dinner", "to_slot_key" => "sun_dinner",
                         "rationale" => "weekend"}, %{plan_id: plan})

    assert result.ok == true
    assert result.label == "Alpha"

    {:ok, state} = PlanningHandler.load_plan(plan)
    assert state.slots["fri_dinner"].recipe_id == b.id
    assert state.slots["sun_dinner"].recipe_id == a.id
  end
```

(Confirm aliases `PlannerTools` and `PlanningHandler` exist in the test file; add if missing.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: FAIL — current `swap_recipe` is a move (sun ends up == Alpha, fri cleared) and returns `%{ok: true}` without `label`.

- [ ] **Step 3: Rewrite swap_recipe's run**

In `lib/tore/llm/planner_tools.ex`, replace the `run:` function of `swap_recipe/0` (currently the load-plan/move/remove `with` chain) with:

```elixir
      run: fn args, ctx ->
        with {:ok, _events} <-
               PlanningHandler.swap_slots(ctx.plan_id, args["from_slot_key"], args["to_slot_key"]),
             {:ok, state} <- PlanningHandler.load_plan(ctx.plan_id) do
          to_slot = Map.get(state.slots, args["to_slot_key"]) || %{}
          {:ok, %{ok: true, label: recipe_title(to_slot[:recipe_id]), recipe_id: to_slot[:recipe_id]}}
        end
      end
```

Add a private helper near `wrap_ok/1` at the bottom of the module:

```elixir
  defp recipe_title(nil), do: nil
  defp recipe_title(recipe_id) do
    Tore.Recipes.get!(recipe_id).title
  rescue
    Ecto.NoResultsError -> nil
  end
```

(Ensure `alias Tore.Recipes` exists or use the fully-qualified `Tore.Recipes.get!`. Check the top of the file; the module already aliases `PlanningHandler`.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: PASS (swap test + existing tool tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(llm): swap_recipe is atomic + returns recipe label"
jj new
```

---

## Task 7: assign_recipe returns label

**Files:**
- Modify: `lib/tore/llm/planner_tools.ex`
- Test: `test/tore/llm/planner_tools_test.exs`

- [ ] **Step 1: Add failing test**

Add to `test/tore/llm/planner_tools_test.exs`:

```elixir
  test "assign_recipe returns the recipe title as label" do
    {:ok, r} = Tore.Recipes.create(%{title: "Roast chicken", recipe_type: :meal, base_servings: 6})
    plan = "plan:tool-assign-1"
    tool = Enum.find(PlannerTools.all(), &(&1.name == "assign_recipe"))

    assert {:ok, result} =
             tool.run.(%{"slot_key" => "mon_dinner", "recipe_id" => r.id, "servings" => 4,
                         "rationale" => "easy"}, %{plan_id: plan})

    assert result.ok == true
    assert result.label == "Roast chicken"
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: FAIL — `assign_recipe` returns `%{ok: true}` (via `wrap_ok`), no `label`.

- [ ] **Step 3: Rewrite assign_recipe's run**

In `lib/tore/llm/planner_tools.ex`, replace `assign_recipe/0`'s `run:` (the `PlanningHandler.assign_recipe(...) |> wrap_ok()`) with:

```elixir
      run: fn args, ctx ->
        with {:ok, _} <-
               PlanningHandler.assign_recipe(
                 ctx.plan_id, args["slot_key"], args["recipe_id"], args["servings"]
               ) do
          {:ok, %{ok: true, label: recipe_title(args["recipe_id"])}}
        end
      end
```

(`recipe_title/1` was added in Task 6.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(llm): assign_recipe returns recipe label"
jj new
```

---

## Task 8: Required rationale arg on all action tools + prompt nudge

**Files:**
- Modify: `lib/tore/llm/planner_tools.ex`
- Modify: `lib/tore/harness/orchestrator.ex` (agent_preamble)
- Test: `test/tore/llm/planner_tools_test.exs`

- [ ] **Step 1: Add a failing test that each action tool requires rationale**

Add to `test/tore/llm/planner_tools_test.exs`:

```elixir
  test "every action tool declares rationale as a required parameter" do
    action_names = ~w(assign_recipe swap_recipe skip_meal mark_leftover set_servings remove_recipe)

    for name <- action_names do
      tool = Enum.find(PlannerTools.all(), &(&1.name == name))
      assert Map.has_key?(tool.parameters.properties, :rationale),
             "#{name} missing rationale property"
      assert "rationale" in tool.parameters.required, "#{name} rationale not required"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: FAIL — no tool declares `rationale`.

- [ ] **Step 3: Add rationale to each action tool**

In `lib/tore/llm/planner_tools.ex`, add a module attribute near `@slot_key` (line ~13):

```elixir
  @rationale %{type: "string",
    description: "One short clause explaining why you are making this change."}
```

Then in each of the six action tools (`assign_recipe`, `swap_recipe`, `skip_meal`, `mark_leftover`, `set_servings`, `remove_recipe`), add `rationale: @rationale` to `properties` and `"rationale"` to the `required` list. Example for `skip_meal`:

```elixir
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key, rationale: @rationale},
        required: ["slot_key", "rationale"]
      },
```

Apply the analogous change to all six. Do NOT touch the read tools (`search_recipes`, `pantry_snapshot`, `active_deals`, `ask_user`).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the prompt nudge**

In `lib/tore/harness/orchestrator.ex`, in `agent_preamble/0`, add one sentence (e.g. after the "Always prefer calling a tool" line):

```
When you call an action tool, always include a short `rationale` saying why.
```

- [ ] **Step 6: Run to verify compile + preamble test (if any) passes**

Run: `mix compile --warnings-as-errors 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(llm): require rationale on action tools + prompt nudge"
jj new
```

---

## Task 9: Full sweep + manual smoke

**Files:** none (verification only).

- [ ] **Step 1: Full harness/planner suite**

Run: `mix test test/tore/harness/ test/tore/llm/ test/tore/handlers/planning_handler_test.exs test/tore_web/components/receipt_live_test.exs test/tore_web/live/planner_live_test.exs 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 2: Full suite (confirm baseline floor unchanged)**

Run: `mix test 2>&1 | tail -8`
Expected: failures only in `Tore.Groceries.*` / `GroceriesHandlerTest` (≤5–6, the known floor). No new failures elsewhere.

- [ ] **Step 3: Compile clean**

Run: `mix compile --force --warnings-as-errors 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 4: Grep audit**

Run: `grep -rn "build_plan_diff" lib/ test/`
Expected: empty.

- [ ] **Step 5: Manual OpenRouter smoke (user-run; agent must NOT handle the key)**

Ask the user to start the server (`OPENROUTER_API_KEY=… iex -S mix phx.server`), and in `iex` run `recompile()` if the server was already running (the dev box has no inotify watcher, so saves do not auto-reload). Then:
1. `/plan` → command bar → `skip mon dinner` → expect receipt "Tore adjusted the plan" + "1 skipped".
2. Assign recipes to two slots, then `swap friday and sunday recipes` → expect "1 swapped", and verify in `iex` that both slots kept their recipes (no data loss):
   ```elixir
   {:ok, s} = Tore.Handlers.PlanningHandler.load_plan("plan:2026-06-01")
   {s.slots["fri_dinner"].recipe_id, s.slots["sun_dinner"].recipe_id}
   ```
   Expect the two ids to be exchanged vs. before, neither nil.
3. Load the latest run and confirm its PlanDiff events reflect the real actions:
   ```elixir
   import Ecto.Query
   sid = Tore.Repo.one(from e in Tore.EventStore.Event,
           where: e.stream_type == "run", order_by: [desc: e.id], limit: 1, select: e.stream_id)
   {:ok, state} = Tore.Harness.Run.load(sid)
   Enum.map(state.artifacts, & &1.__struct__)
   ```

- [ ] **Step 6: Final commit**

```bash
jj describe -m "test(harness): real-PlanDiff passes full sweep + manual smoke"
jj new
```

---

## Self-Review Notes

**Spec coverage:**
- Data flow / builder → Task 3.
- Tool→event mapping → Task 3 (`event_for/3`).
- Recipe label → Tasks 6 (swap) + 7 (assign).
- PlanDiff artifact changes (rollup + type) → Task 1.
- RunSummary wording → Task 2.
- Required rationale arg + prompt nudge → Task 8.
- Atomic swap fix (`swap_slots/3` + tool rewrite) → Tasks 5 + 6.
- Orchestrator uses builder, deletes placeholder → Task 4.
- Testing + success criteria → per-task tests + Task 9.

**Type consistency:** `PlanDiffBuilder.build/2` returns `%PlanDiff{}` with `events: [event_entry]` matching PlanDiff's `@type event_entry` (string-keyed payloads, `rationale: [String]`). New event_type strings (`RecipeSwapped`, `ServingsChanged`) match the rollup mapping in Task 1. `swap_slots/3` returns `{:ok, [event]} | {:error, :nothing_to_swap}`, consumed by the tool in Task 6. `recipe_title/1` defined in Task 6, reused in Task 7.

**Ordering note:** Task 6 depends on Task 5 (`swap_slots/3`) and defines `recipe_title/1` used by Task 7. Tasks 1–3 are independent of 5–7. Task 4 depends on Task 3. Task 8 is independent. Execute in numeric order.
