defmodule Tore.Harness.KitchenRunTest do
  use Tore.DataCase, async: true

  alias Tore.Harness.Artifact.{CostEntry, PlanDiff}
  alias Tore.Harness.KitchenRun
  alias Tore.Harness.KitchenRun.Transition
  alias Tore.Repo

  @now ~U[2026-11-10 12:00:00.000000Z]

  defp open!(attrs \\ %{}) do
    home_scope()
    |> KitchenRun.open(
      Map.merge(%{kind: "test_run", actor: :user, input: %{command: "plan tuesday"}}, attrs),
      @now
    )
    |> Repo.insert!()
  end

  defp get!(id), do: Repo.get!(KitchenRun, id, household_id: home_scope().household_id)

  defp move!(run, action) do
    {:ok, changes} = Transition.next(run, action, @now)
    run |> KitchenRun.change(changes) |> Repo.update!()
  end

  test "a run written and read back is equal, artifacts and undo included" do
    run = open!(%{surface: :plan, phase: :proposing})

    artifacts = [
      %PlanDiff{
        plan_stream_id: "plan-1",
        week_start: ~D[2026-11-09],
        events: [
          %{
            slot_key: "tue_dinner",
            event_type: "RecipeAssigned",
            payload: %{"recipe_id" => 1, "label" => "Ärtsoppa"},
            rationale: ["asked for"]
          }
        ]
      },
      %CostEntry{
        store_name: "ICA",
        date: ~D[2026-11-09],
        total: Decimal.new("123.45"),
        line_items: []
      }
    ]

    run =
      run
      |> KitchenRun.change(%{
        artifacts: artifacts,
        prompt_tokens: 10,
        completion_tokens: 5,
        cost_usd: Decimal.new("0.0125")
      })
      |> Repo.update!()

    applied = move!(run, {:apply, {:steps, [{:delete_receipt, 3}]}})

    assert applied == get!(run.id)
    assert applied.input == %{"command" => "plan tuesday"}
  end

  test "values SQLite would hand back differently are normalised when set" do
    run =
      home_scope()
      |> KitchenRun.open(%{kind: "test_run", actor: :user, input: %{}}, ~U[2026-11-10 12:00:00Z])
      |> Repo.insert!()
      |> KitchenRun.change(%{cost_usd: Decimal.new("1E+2")})
      |> Repo.update!()

    assert run == get!(run.id)
  end

  test "input JSON can't hold is refused" do
    for input <- [%{t: {1, 2}}, ~D[2026-11-10], %{:a => 1, "a" => 2}] do
      refute KitchenRun.open(home_scope(), %{kind: "k", actor: :user, input: input}, @now).valid?
    end
  end

  test "a failed run keeps its code and repair, and reads back the same" do
    failed = open!() |> move!({:fail, :slot_pinned, "Pinned", {:edit_plan, ["mon_dinner"]}})

    assert failed == get!(failed.id)
    assert failed.repair_action == {:edit_plan, ["mon_dinner"]}
  end

  test "a failure code outside the list is refused" do
    {:ok, changes} = Transition.next(open!(), {:fail, :made_up, nil, nil}, @now)
    refute KitchenRun.change(open!(), changes).valid?
  end

  test "another household can't read the run" do
    run = open!()
    other = household_fixture()
    assert Repo.get(KitchenRun, run.id, household_id: other.id) == nil
  end

  describe "the table refuses rows the transitions can't produce" do
    defp force!(run, changes) do
      run |> Ecto.Changeset.change(changes) |> Repo.update!()
    end

    test "needs_user without a question" do
      assert_raise Ecto.ConstraintError, ~r/check_constraint/, fn ->
        force!(open!(), %{status: :needs_user})
      end
    end

    test "applied without an undo" do
      assert_raise Ecto.ConstraintError, ~r/check_constraint/, fn ->
        force!(open!(), %{status: :applied, applied_at: @now})
      end
    end

    test "failed without a code" do
      assert_raise Ecto.ConstraintError, ~r/check_constraint/, fn ->
        force!(open!(), %{status: :failed, closed_at: @now})
      end
    end

    test "reverted that was never applied" do
      assert_raise Ecto.ConstraintError, ~r/check_constraint/, fn ->
        force!(open!(), %{status: :reverted, reverted_at: @now})
      end
    end

    test "discarded without a reason" do
      assert_raise Ecto.ConstraintError, ~r/check_constraint/, fn ->
        force!(open!(), %{status: :discarded, closed_at: @now})
      end
    end
  end
end
