defmodule Tore.Harness.Artifact.PlanDiffTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Artifact.PlanDiff

  defp ev(slot, type, payload \\ %{}, rationale \\ ["because"]) do
    %{slot_key: slot, event_type: type, payload: payload, rationale: rationale}
  end

  test "kind/0" do
    assert PlanDiff.kind() == "PlanDiff"
  end

  test "enforce_keys: requires plan_stream_id, week_start, events" do
    assert_raise ArgumentError, fn -> struct!(PlanDiff, %{}) end
  end

  test "summarise/1: single MealSkipped event yields :skipped rollup" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("mon_dinner", "MealSkipped")]
    }

    [entry] = PlanDiff.summarise(diff)
    assert entry.slot_key == "mon_dinner"
    assert entry.change == :skipped
    assert entry.rationale == ["because"]
  end

  test "summarise/1: RecipeAssigned alone yields :added" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("tue_dinner", "RecipeAssigned", %{"label" => "Stew"})]
    }

    [entry] = PlanDiff.summarise(diff)
    assert entry.change == :added
    assert entry.label == "Stew"
  end

  test "summarise/1: LeftoverMarked yields :leftover" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("wed_dinner", "LeftoverMarked")]
    }

    [entry] = PlanDiff.summarise(diff)
    assert entry.change == :leftover
  end

  test "summarise/1: RecipeRemoved alone yields :removed" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("thu_dinner", "RecipeRemoved")]
    }

    [entry] = PlanDiff.summarise(diff)
    assert entry.change == :removed
  end

  test "to_json/1 and from_json/1 round-trip" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("mon", "MealSkipped")]
    }

    encoded = PlanDiff.to_json(diff)
    decoded = PlanDiff.from_json(encoded)
    assert decoded.plan_stream_id == "plan-1"
    assert decoded.week_start == ~D[2026-06-01]
    assert length(decoded.events) == 1
  end

  test "summarise/1 maps RecipeSwapped to :swapped" do
    diff = %PlanDiff{
      plan_stream_id: "p",
      week_start: ~D[2026-06-01],
      events: [
        %{
          slot_key: "sun_dinner",
          event_type: "RecipeSwapped",
          payload: %{"from_slot_key" => "fri_dinner", "to_slot_key" => "sun_dinner"},
          rationale: ["because"]
        }
      ]
    }

    assert [%{slot_key: "sun_dinner", change: :swapped}] = PlanDiff.summarise(diff)
  end

  test "summarise/1 maps ServingsChanged to :servings" do
    diff = %PlanDiff{
      plan_stream_id: "p",
      week_start: ~D[2026-06-01],
      events: [
        %{
          slot_key: "mon_dinner",
          event_type: "ServingsChanged",
          payload: %{"servings" => 6},
          rationale: ["more guests"]
        }
      ]
    }

    assert [%{slot_key: "mon_dinner", change: :servings}] = PlanDiff.summarise(diff)
  end

  test "summarise/1 maps a lone RecipeAssigned to :added and lone RecipeRemoved to :removed" do
    diff = %PlanDiff{
      plan_stream_id: "p",
      week_start: ~D[2026-06-01],
      events: [
        %{slot_key: "mon_dinner", event_type: "RecipeAssigned", payload: %{}, rationale: ["x"]},
        %{slot_key: "tue_dinner", event_type: "RecipeRemoved", payload: %{}, rationale: ["y"]}
      ]
    }

    rollup = PlanDiff.summarise(diff)
    assert Enum.find(rollup, &(&1.slot_key == "mon_dinner")).change == :added
    assert Enum.find(rollup, &(&1.slot_key == "tue_dinner")).change == :removed
  end
end
