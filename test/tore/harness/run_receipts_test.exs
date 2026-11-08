defmodule Tore.Harness.RunReceiptsTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.{Run, RunReceipts, UndoPayload}
  alias Tore.Harness.Run.{Commands, Events, State}
  alias Tore.Harness.Artifact.{PantryBeliefUpdate, PlanDiff, RunSummary}

  defp seed_applied_run(household_id, artifacts) do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: household_id,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{command: "do thing"}
        },
        %State.Draft{stream_id: sid}
      )

    artifact_events = Enum.map(artifacts, &%Events.ArtifactAdded{artifact: &1})

    payload = UndoPayload.from_artifacts(artifacts)
    committed = %Events.Committed{at: ~U[2026-06-28 12:00:00Z], undo_payload: payload}

    :ok = Run.append(sid, [opened] ++ artifact_events ++ [committed])
    sid
  end

  defp plan_diff do
    %PlanDiff{
      plan_stream_id: "plan-h1-w1",
      week_start: ~D[2026-06-22],
      events: [
        %{
          slot_key: "2026-06-23-dinner",
          event_type: "RecipeAssigned",
          payload: %{"label" => "Pasta"},
          rationale: ["uses leftover salmon"]
        }
      ]
    }
  end

  defp pantry_update do
    %PantryBeliefUpdate{
      items: [
        %{
          name: "olive oil",
          change: :added,
          quantity: nil,
          unit: nil,
          category: nil,
          provenance: "receipt",
          last_seen_at: ~U[2026-06-28 12:00:00Z]
        }
      ]
    }
  end

  describe "get/1" do
    test "returns a receipt for an Applied run" do
      sid = seed_applied_run(1, [plan_diff()])

      assert {:ok, receipt} = RunReceipts.get(sid)
      assert receipt.stream_id == sid
      assert receipt.household_id == 1
      assert receipt.applied_at == ~U[2026-06-28 12:00:00Z]
      assert receipt.reverted_at == nil
      assert %UndoPayload{kind: :event_sourced} = receipt.undo_payload
    end

    test "returns {:error, :not_applied} for a Running run" do
      sid = Run.next_stream_id()

      {:ok, [opened]} =
        Run.decide(
          %Commands.Open{
            household_id: 1,
            kind: "planner_command_run",
            surface: :plan,
            started_by: "user",
            user_id: 1,
            input: %{}
          },
          %State.Draft{stream_id: sid}
        )

      :ok = Run.append(sid, [opened])
      assert {:error, :not_applied} = RunReceipts.get(sid)
    end

    test "returns {:error, :not_found} for an unknown stream" do
      assert {:error, :not_found} = RunReceipts.get("run-never-seen")
    end
  end

  describe "to_diff_rows/1" do
    test "projects a PlanDiff into one DiffRow per slot event" do
      rows = RunReceipts.to_diff_rows([plan_diff()])
      assert [row] = rows
      assert row.surface == :plan
      assert row.op == :added
      assert row.label =~ "Pasta"
    end

    test "projects a PantryBeliefUpdate :added item into a pantry DiffRow with op :added" do
      rows = RunReceipts.to_diff_rows([pantry_update()])
      assert [row] = rows
      assert row.surface == :pantry
      assert row.op == :added
      assert row.label =~ "olive oil"
    end

    test "ignores RunSummary artifacts (they describe, not change)" do
      summary = %RunSummary{counts: %{}, outcome: :applied}
      rows = RunReceipts.to_diff_rows([summary])
      assert rows == []
    end

    test "combines multiple artifacts in order" do
      rows = RunReceipts.to_diff_rows([plan_diff(), pantry_update()])
      assert length(rows) == 2
      assert Enum.map(rows, & &1.surface) == [:plan, :pantry]
    end
  end

  describe "list_for_household/2" do
    test "returns Applied receipts for the given household, newest first" do
      sid1 = seed_applied_run(7, [plan_diff()])
      sid2 = seed_applied_run(7, [pantry_update()])
      _other = seed_applied_run(8, [plan_diff()])

      receipts = RunReceipts.list_for_household(7)
      stream_ids = Enum.map(receipts, & &1.stream_id)

      assert sid1 in stream_ids
      assert sid2 in stream_ids
      assert length(receipts) == 2
    end
  end

  describe "revert/1" do
    test "transitions an Applied run to Reverted" do
      sid = seed_applied_run(1, [plan_diff()])

      assert :ok = RunReceipts.revert(sid)
      {:ok, state} = Run.load(sid)
      assert %State.Reverted{} = state
    end

    test "compensates a real set_plan_slot Run by clearing the slot" do
      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Pasta",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      date = ~D[2026-06-23]

      {:ok, %{stream_id: sid}} =
        Tore.Harness.Orchestrator.apply_set_plan_slot(%{
          household_id: 1,
          user_id: 1,
          date: date,
          recipe_id: recipe.id,
          servings: 4
        })

      plan_id = "plan:2026-06-22"
      {:ok, before_revert} = Tore.Planning.load_plan(plan_id)
      assert Map.has_key?(before_revert.slots, "tue_dinner")

      assert :ok = RunReceipts.revert(sid)

      {:ok, after_revert} = Tore.Planning.load_plan(plan_id)
      refute Map.has_key?(after_revert.slots, "tue_dinner")

      {:ok, state} = Run.load(sid)
      assert %State.Reverted{} = state
    end

    test "returns {:error, :irreversible} when undo_payload is irreversible" do
      cost = %Tore.Harness.Artifact.CostEntry{
        store_name: "ICA",
        date: ~D[2026-06-28],
        total: Decimal.new("10"),
        line_items: []
      }

      sid = seed_applied_run(1, [cost])

      assert {:error, :irreversible} = RunReceipts.revert(sid)
      {:ok, state} = Run.load(sid)
      assert %State.Applied{} = state
    end

    test "returns {:error, :not_applied} for a run that is not Applied" do
      assert {:error, :not_found} = RunReceipts.revert("run-never-seen")
    end

    test "compensates a PantrySnapshot by deleting newly-added rows" do
      {:ok, ingredient} =
        %Tore.Recipes.Ingredient{
          household_id: home_scope().household_id,
          name: "salt",
          key: "salt"
        }
        |> Tore.Repo.insert()

      {:ok, item} =
        Tore.Pantry.add_item(home_scope(), %{
          name: "salt",
          ingredient_id: ingredient.id,
          provenance: "manual"
        })

      snapshot = %Tore.Harness.Artifact.PantrySnapshot{
        items: [%{item_id: item.id, before: nil, after: %{quantity: nil}}]
      }

      sid = seed_applied_run(1, [snapshot])

      assert :ok = RunReceipts.revert(sid)

      assert Tore.Repo.get(Tore.Pantry.PantryItem, item.id, Tore.Scope.repo_opts(home_scope())) ==
               nil
    end

    test "compensates a PantrySnapshot by restoring before-state on bumped rows" do
      {:ok, ingredient} =
        %Tore.Recipes.Ingredient{
          household_id: home_scope().household_id,
          name: "olive oil",
          key: "olive_oil"
        }
        |> Tore.Repo.insert()

      {:ok, item} =
        Tore.Pantry.add_item(home_scope(), %{
          name: "olive oil",
          ingredient_id: ingredient.id,
          provenance: "manual",
          quantity: Decimal.new("1"),
          unit: "L"
        })

      # Simulate a bump that happened during the run.
      {:ok, _} =
        item
        |> Tore.Pantry.PantryItem.changeset(%{quantity: Decimal.new("3"), provenance: "receipt"})
        |> Tore.Repo.update()

      snapshot = %Tore.Harness.Artifact.PantrySnapshot{
        items: [
          %{
            item_id: item.id,
            before: %{
              quantity: "1",
              unit: "L",
              last_seen_at: nil,
              provenance: "manual",
              belief: nil
            },
            after: %{quantity: "3"}
          }
        ]
      }

      sid = seed_applied_run(1, [snapshot])

      assert :ok = RunReceipts.revert(sid)

      restored =
        Tore.Repo.get(Tore.Pantry.PantryItem, item.id, Tore.Scope.repo_opts(home_scope()))

      assert Decimal.equal?(restored.quantity, Decimal.new("1"))
      assert restored.provenance == "manual"
    end

    test "rolls back the planning compensator if a later snapshot compensator fails" do
      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Soup",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      date = ~D[2026-06-23]

      {:ok, %{stream_id: sid}} =
        Tore.Harness.Orchestrator.apply_set_plan_slot(%{
          household_id: 1,
          user_id: 1,
          date: date,
          recipe_id: recipe.id,
          servings: 4
        })

      plan_id = "plan:2026-06-22"
      {:ok, before_state} = Tore.Planning.load_plan(plan_id)
      assert Map.has_key?(before_state.slots, "tue_dinner")

      # Splice a failing snapshot child onto the existing payload so the
      # composite has: child A (event_sourced planning, succeeds) and
      # child B (snapshot with an invalid belief value, fails validation).
      {:ok, ingredient} =
        %Tore.Recipes.Ingredient{
          household_id: home_scope().household_id,
          name: "rice",
          key: "rice"
        }
        |> Tore.Repo.insert()

      {:ok, item} =
        Tore.Pantry.add_item(home_scope(), %{
          name: "rice",
          ingredient_id: ingredient.id,
          provenance: "manual"
        })

      {:ok, %State.Applied{} = applied} = Run.load(sid)

      bad_snapshot = %UndoPayload{
        kind: :snapshot,
        data: %{
          schema: "Tore.Pantry.PantryItem",
          changes: [
            %{item_id: item.id, before: %{quantity: "1", belief: "not_a_real_belief"}}
          ]
        }
      }

      doctored =
        case applied.undo_payload do
          %UndoPayload{kind: :composite, data: %{children: children}} ->
            %UndoPayload{kind: :composite, data: %{children: children ++ [bad_snapshot]}}

          single ->
            %UndoPayload{kind: :composite, data: %{children: [single, bad_snapshot]}}
        end

      doctored_applied = %{applied | undo_payload: doctored}

      assert {:error, _} = RunReceipts.revert_applied(doctored_applied)

      {:ok, after_state} = Tore.Planning.load_plan(plan_id)

      assert Map.has_key?(after_state.slots, "tue_dinner"),
             "planning slot was wiped despite a downstream compensator failure"

      {:ok, state} = Run.load(sid)
      assert %State.Applied{} = state
    end
  end
end
