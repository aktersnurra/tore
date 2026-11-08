defmodule Tore.Harness.UndoPayloadTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.UndoPayload
  alias Tore.Harness.Artifact.{CostEntry, PantryBeliefUpdate, PlanDiff, RunSummary}

  describe "from_artifacts/1" do
    test "returns :irreversible with reason when artifacts list is empty" do
      assert %UndoPayload{kind: :irreversible, data: %{reason: reason}} =
               UndoPayload.from_artifacts([])

      assert reason =~ "no reversible artifacts"
    end

    test "returns event_sourced payload for a PlanDiff artifact" do
      diff = %PlanDiff{
        plan_stream_id: "plan-h1-w1",
        week_start: ~D[2026-06-22],
        events: [
          %{
            slot_key: "2026-06-23-dinner",
            event_type: "RecipeAssigned",
            payload: %{"recipe_id" => 1, "label" => "Pasta"},
            rationale: ["uses leftover salmon"]
          }
        ]
      }

      assert %UndoPayload{kind: :event_sourced, data: data} =
               UndoPayload.from_artifacts([diff])

      assert data.stream_id == "plan-h1-w1"
      assert data.stream_type == "planning"
      assert is_list(data.event_types)
      assert "RecipeAssigned" in data.event_types
    end

    test "returns snapshot payload for a PantryBeliefUpdate artifact" do
      update = %PantryBeliefUpdate{
        items: [
          %{
            name: "olive oil",
            change: :added,
            quantity: nil,
            unit: nil,
            category: nil,
            provenance: "receipt",
            last_seen_at: ~U[2026-06-27 12:00:00Z]
          }
        ]
      }

      assert %UndoPayload{kind: :snapshot, data: data} =
               UndoPayload.from_artifacts([update])

      assert data.schema == "Tore.Pantry.PantryItem"
      assert is_list(data.changes)
      assert hd(data.changes).change == :added
    end

    test "returns irreversible for a CostEntry artifact" do
      entry = %CostEntry{
        store_name: "ICA",
        date: ~D[2026-06-27],
        total: Decimal.new("123.45"),
        line_items: []
      }

      assert %UndoPayload{kind: :irreversible, data: %{reason: reason}} =
               UndoPayload.from_artifacts([entry])

      assert reason =~ "cost"
    end

    test "returns composite payload for multiple reversible artifacts" do
      diff = %PlanDiff{
        plan_stream_id: "plan-h1-w1",
        week_start: ~D[2026-06-22],
        events: [
          %{
            slot_key: "2026-06-23-dinner",
            event_type: "RecipeAssigned",
            payload: %{},
            rationale: ["x"]
          }
        ]
      }

      update = %PantryBeliefUpdate{
        items: [
          %{
            name: "olive oil",
            change: :added,
            quantity: nil,
            unit: nil,
            category: nil,
            provenance: "receipt",
            last_seen_at: ~U[2026-06-27 12:00:00Z]
          }
        ]
      }

      assert %UndoPayload{kind: :composite, data: %{children: children}} =
               UndoPayload.from_artifacts([diff, update])

      assert length(children) == 2
      assert Enum.any?(children, &(&1.kind == :event_sourced))
      assert Enum.any?(children, &(&1.kind == :snapshot))
    end

    test "RunSummary alongside a reversible artifact does not appear as a child" do
      diff = %PlanDiff{
        plan_stream_id: "plan-h1-w1",
        week_start: ~D[2026-06-22],
        events: [
          %{
            slot_key: "2026-06-23-dinner",
            event_type: "RecipeAssigned",
            payload: %{},
            rationale: []
          }
        ]
      }

      summary = %RunSummary{counts: %{}, outcome: :applied}

      payload = UndoPayload.from_artifacts([diff, summary])

      # The summary contributes no reversal; the payload should be the
      # bare event_sourced child, not a composite with a noop sibling.
      assert %UndoPayload{kind: :event_sourced} = payload
      assert payload.kind in UndoPayload.kinds()
    end

    test "every payload kind a non-empty run can produce is declared in kinds/0" do
      diff = %PlanDiff{
        plan_stream_id: "p",
        week_start: ~D[2026-06-22],
        events: [%{slot_key: "s", event_type: "RecipeAssigned", payload: %{}, rationale: []}]
      }

      update = %PantryBeliefUpdate{
        items: [
          %{
            name: "x",
            change: :added,
            quantity: nil,
            unit: nil,
            category: nil,
            provenance: "receipt",
            last_seen_at: ~U[2026-06-27 12:00:00Z]
          }
        ]
      }

      cost = %CostEntry{
        store_name: "ICA",
        date: ~D[2026-06-27],
        total: Decimal.new("1"),
        line_items: []
      }

      summary = %RunSummary{counts: %{}, outcome: :applied}

      for artifacts <- [
            [diff],
            [update],
            [cost],
            [summary],
            [diff, update, summary],
            [diff, cost]
          ] do
        %UndoPayload{kind: k} = UndoPayload.from_artifacts(artifacts)
        assert k in UndoPayload.kinds(), "kind #{inspect(k)} escaped from #{inspect(artifacts)}"
      end
    end

    test "an irreversible child in a composite makes the composite irreversible" do
      diff = %PlanDiff{
        plan_stream_id: "plan-h1-w1",
        week_start: ~D[2026-06-22],
        events: [
          %{
            slot_key: "2026-06-23-dinner",
            event_type: "RecipeAssigned",
            payload: %{},
            rationale: ["x"]
          }
        ]
      }

      cost = %CostEntry{
        store_name: "ICA",
        date: ~D[2026-06-27],
        total: Decimal.new("10"),
        line_items: []
      }

      assert %UndoPayload{kind: :irreversible, data: %{reason: reason}} =
               UndoPayload.from_artifacts([diff, cost])

      assert reason =~ "contains an irreversible"
    end
  end

  describe "compose/1" do
    test "returns :irreversible when no child payloads given" do
      assert %UndoPayload{kind: :irreversible} = UndoPayload.compose([])
    end

    test "returns the lone payload when given a single child" do
      payload = %UndoPayload{kind: :irreversible, data: %{reason: "x"}}
      assert UndoPayload.compose([payload]) == payload
    end

    test "wraps multiple reversible children in :composite" do
      a = %UndoPayload{kind: :snapshot, data: %{schema: "X", changes: []}}

      b = %UndoPayload{
        kind: :event_sourced,
        data: %{stream_id: "y", stream_type: "z", event_types: []}
      }

      assert %UndoPayload{kind: :composite, data: %{children: [^a, ^b]}} =
               UndoPayload.compose([a, b])
    end

    test "becomes :irreversible if any child is :irreversible" do
      a = %UndoPayload{kind: :snapshot, data: %{schema: "X", changes: []}}
      b = %UndoPayload{kind: :irreversible, data: %{reason: "y"}}

      assert %UndoPayload{kind: :irreversible, data: %{reason: reason}} =
               UndoPayload.compose([a, b])

      assert reason =~ "irreversible"
    end

    test "skips nil children (children that produced no reversible payload)" do
      a = %UndoPayload{kind: :snapshot, data: %{schema: "X", changes: []}}
      assert UndoPayload.compose([a, nil]) == a
    end
  end

  describe "json round-trip" do
    test "event_sourced encodes and decodes" do
      payload = %UndoPayload{
        kind: :event_sourced,
        data: %{
          stream_id: "plan-1",
          stream_type: "planning",
          event_types: ["RecipeAssigned"],
          compensating_events: [
            %{event_type: "RecipeRemoved", slot_key: "tue_dinner", payload: %{}}
          ]
        }
      }

      assert payload |> UndoPayload.to_json() |> UndoPayload.from_json() == payload
    end

    test "snapshot encodes and decodes" do
      payload = %UndoPayload{
        kind: :snapshot,
        data: %{
          schema: "Tore.Pantry.PantryItem",
          changes: [%{change: :added, name: "olive oil"}]
        }
      }

      decoded = payload |> UndoPayload.to_json() |> UndoPayload.from_json()
      assert decoded.kind == :snapshot
      assert decoded.data.schema == "Tore.Pantry.PantryItem"
      assert hd(decoded.data.changes).change == :added
    end

    test "irreversible encodes and decodes" do
      payload = %UndoPayload{kind: :irreversible, data: %{reason: "nothing here"}}
      assert payload |> UndoPayload.to_json() |> UndoPayload.from_json() == payload
    end

    test "composite encodes and decodes recursively" do
      payload = %UndoPayload{
        kind: :composite,
        data: %{
          children: [
            %UndoPayload{
              kind: :event_sourced,
              data: %{
                stream_id: "plan-1",
                stream_type: "planning",
                event_types: [],
                compensating_events: []
              }
            },
            %UndoPayload{kind: :irreversible, data: %{reason: "x"}}
          ]
        }
      }

      decoded = payload |> UndoPayload.to_json() |> UndoPayload.from_json()
      assert decoded.kind == :composite
      assert length(decoded.data.children) == 2
      assert Enum.at(decoded.data.children, 0).kind == :event_sourced
      assert Enum.at(decoded.data.children, 1).kind == :irreversible
    end
  end
end
