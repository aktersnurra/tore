defmodule Tore.Harness.PlanDiffBuilderTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.PlanDiffBuilder
  alias Tore.Harness.Artifact.PlanDiff

  @ctx %{plan_stream_id: "plan:1:2026-06-01", week_start: ~D[2026-06-01]}

  defp calls_entry(idx, calls) do
    encoded =
      Jason.encode!(Enum.map(calls, fn {id, name, args} -> %{id: id, name: name, args: args} end))

    %{step_index: idx, step_kind: :tool_calls, payload: %{calls: encoded}}
  end

  defp result_entry(idx, id, name, result) do
    %{
      step_index: idx,
      step_kind: :tool_result,
      payload: %{tool_call_id: id, name: name, result: result}
    }
  end

  test "skip_meal success becomes one MealSkipped event with rationale" do
    trace = [
      calls_entry(0, [{"c1", "skip_meal", %{"slot_key" => "mon_dinner", "rationale" => "busy"}}]),
      result_entry(1, "c1", "skip_meal", %{ok: true})
    ]

    diff = PlanDiffBuilder.build(trace, @ctx)

    assert %PlanDiff{
             plan_stream_id: "plan:1:2026-06-01",
             week_start: ~D[2026-06-01]
           } = diff

    assert [
             %{
               slot_key: "mon_dinner",
               event_type: "MealSkipped",
               payload: %{},
               rationale: ["busy"]
             }
           ] =
             diff.events
  end

  test "assign_recipe carries recipe_id, servings, label into payload" do
    trace = [
      calls_entry(0, [
        {"c1", "assign_recipe",
         %{"slot_key" => "mon_dinner", "recipe_id" => 7, "servings" => 4, "rationale" => "quick"}}
      ]),
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
      calls_entry(0, [
        {"c1", "swap_recipe",
         %{
           "from_slot_key" => "fri_dinner",
           "to_slot_key" => "sun_dinner",
           "rationale" => "prefer weekend"
         }}
      ]),
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
      calls_entry(0, [
        {"c1", "set_servings",
         %{"slot_key" => "mon_dinner", "servings" => 6, "rationale" => "guests"}}
      ]),
      result_entry(1, "c1", "set_servings", %{ok: true})
    ]

    [event] = PlanDiffBuilder.build(trace, @ctx).events
    assert event.event_type == "ServingsChanged"
    assert event.payload["servings"] == 6
  end

  test "mark_leftover becomes LeftoverMarked" do
    trace = [
      calls_entry(0, [
        {"c1", "mark_leftover", %{"slot_key" => "wed_dinner", "rationale" => "uses sunday roast"}}
      ]),
      result_entry(1, "c1", "mark_leftover", %{ok: true})
    ]

    [event] = PlanDiffBuilder.build(trace, @ctx).events
    assert event.event_type == "LeftoverMarked"
    assert event.slot_key == "wed_dinner"
    assert event.rationale == ["uses sunday roast"]
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
