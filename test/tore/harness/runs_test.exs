defmodule Tore.Harness.RunsTest do
  use Tore.DataCase, async: false

  alias Tore.Costs
  alias Tore.Harness.{KitchenRun, Runs, TestKind}
  alias Tore.Harness.Artifact.CostEntry

  @entry %CostEntry{
    store_name: "ICA",
    date: ~D[2026-11-09],
    total: Decimal.new("120.00"),
    line_items: []
  }

  # A member of Home, since a receipt records who logged it.
  setup do
    scope = scope_fixture(user_fixture())
    Process.put(:scope, scope)
    Phoenix.PubSub.subscribe(Tore.PubSub, Runs.topic(scope))
    :ok
  end

  defp scope, do: Process.get(:scope)
  defp start(ctx), do: Runs.start(scope(), TestKind, ctx)
  defp receipts, do: Costs.recent_receipts(scope(), 10)

  describe "start" do
    test "applies a verified proposal, records usage, and the run reads back the same" do
      assert {:ok, %KitchenRun{status: :applied} = run} = start(%{entry: @entry})

      assert run == Runs.get(scope(), run.id)
      assert run.actor == :user and run.surface == :shop
      assert run.prompt_tokens == 3 and Decimal.equal?(run.cost_usd, "0.25")
      assert [%CostEntry{store_name: "ICA"}] = run.artifacts
      assert [%{store_name: "ICA"}] = receipts()
      assert_receive {:run_changed, %KitchenRun{id: id, status: :applied}}
      assert id == run.id
    end

    test "a question leaves the run waiting with it" do
      assert {:ok, %KitchenRun{status: :needs_user, question: "Which store?"}} =
               start(%{mode: "ask"})
    end

    test "a proposal to review waits on the run, and nothing is written" do
      assert {:ok, %KitchenRun{status: :needs_user} = run} =
               start(%{entry: %{@entry | store_name: "Granska"}})

      assert [%CostEntry{store_name: "Granska"}] = run.artifacts
      assert receipts() == []
      assert [%{id: id}] = Runs.list_pending(scope())
      assert id == run.id
    end

    test "a proposal the verifier refuses fails the run and writes nothing" do
      assert {:ok, %KitchenRun{status: :failed, failure_code: :missing_store}} =
               start(%{entry: %{@entry | store_name: ""}})

      assert receipts() == []
    end

    test "a refused LLM call fails the run with the refusal, so the screen can say why" do
      assert {:error, {:step_failed, :ai_unavailable}} = start(%{mode: "refuse"})

      assert %KitchenRun{failure_code: :ai_unavailable} =
               Runs.latest_on_surface(scope(), :shop)
    end

    test "a crash fails the run" do
      assert {:error, {:run_crashed, %RuntimeError{}}} = start(%{mode: "crash"})

      assert %KitchenRun{status: :failed, failure_code: :internal_error} =
               Runs.latest_on_surface(scope(), :shop)
    end

    test "an exit fails the run, as a crash does" do
      assert {:error, {:run_crashed, :timeout}} = start(%{mode: "exit"})
      assert %KitchenRun{status: :failed} = Runs.latest_on_surface(scope(), :shop)
    end

    test "a move the kind gets wrong, such as a blank question, fails the run instead of leaving it running" do
      assert {:error, {:run_crashed, %MatchError{}}} = start(%{mode: "blank_question"})

      assert %KitchenRun{status: :failed, failure_code: :internal_error} =
               Runs.latest_on_surface(scope(), :shop)
    end

    test "a failing after_commit doesn't undo the result, and the change is still announced" do
      assert {:ok, %KitchenRun{status: :applied}} =
               start(%{mode: "after_commit_raises", entry: @entry})

      assert_receive {:run_changed, %KitchenRun{status: :applied}}
      assert [_] = receipts()
    end

    test "an apply that errors after writing leaves no write behind" do
      assert {:error, {:step_failed, :later_step_failed}} =
               start(%{mode: "write_then_error", entry: @entry})

      assert receipts() == []

      assert %KitchenRun{status: :failed, failure_code: :internal_error} =
               Runs.latest_on_surface(scope(), :shop)
    end
  end

  test "submit applies a proposal without proposing" do
    assert {:ok, %KitchenRun{status: :applied, prompt_tokens: 0}} =
             Runs.submit(scope(), TestKind, @entry, %{})

    assert [_] = receipts()
  end

  describe "confirm" do
    setup do
      {:ok, run} = start(%{entry: %{@entry | store_name: "Granska"}})
      %{run: run}
    end

    test "applies the proposal as the person left it", %{run: run} do
      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.confirm(scope(), run.id, %{@entry | store_name: "Coop"})

      assert [%{store_name: "Coop"}] = receipts()
    end

    test "an edit the verifier refuses leaves the run waiting", %{run: run} do
      assert {:error, {:verifier_failed, :missing_store, _}} =
               Runs.confirm(scope(), run.id, %{@entry | store_name: ""})

      assert %KitchenRun{status: :needs_user} = Runs.get(scope(), run.id)
      assert receipts() == []
    end

    test "a second confirm is refused, so nothing is written twice", %{run: run} do
      assert {:ok, _} = Runs.confirm(scope(), run.id, @entry)

      assert {:error, {:invalid_transition, :applied, :confirm}} =
               Runs.confirm(scope(), run.id, @entry)

      assert [_] = receipts()
    end

    test "discarding closes it with the reason", %{run: run} do
      assert {:ok, %KitchenRun{status: :discarded, discard_reason: :user_discarded}} =
               Runs.discard(scope(), run.id, :user_discarded)

      assert Runs.list_pending(scope()) == []
    end

    test "another household can't see, confirm, discard or revert it", %{run: run} do
      other = scope_fixture(household_fixture())

      assert Runs.get(other, run.id) == nil
      assert {:error, :not_found} = Runs.confirm(other, run.id, @entry)
      assert {:error, :not_found} = Runs.discard(other, run.id, :user_discarded)
      assert {:error, :not_found} = Runs.revert(other, run.id)
    end
  end

  test "a run discarded while its confirm is under way stays discarded, with nothing written" do
    {:ok, run} = start(%{mode: "race_discard", entry: %{@entry | store_name: "Granska"}})

    assert {:error, {:status_changed, :discarded}} = Runs.confirm(scope(), run.id, @entry)
    assert %KitchenRun{status: :discarded} = Runs.get(scope(), run.id)
    assert receipts() == []
  end

  describe "revert" do
    test "restores what the run changed, once" do
      {:ok, run} = start(%{entry: @entry})

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(scope(), run.id)
      assert receipts() == []

      assert {:error, {:invalid_transition, :reverted, :revert}} =
               Runs.revert(scope(), run.id)
    end

    test "a step that can't be undone rolls the whole revert back" do
      {:ok, run} = start(%{entry: @entry})
      [receipt] = receipts()
      :ok = Costs.delete_receipt(scope(), receipt.id)

      assert_raise MatchError, fn -> Runs.revert(scope(), run.id) end
      assert %KitchenRun{status: :applied} = Runs.get(scope(), run.id)
    end
  end

  test "at boot, runs still running in any household fail as interrupted, and nothing else changes" do
    other = scope_fixture(household_fixture())
    {:ok, applied} = start(%{entry: @entry})

    running =
      for scope <- [scope(), other] do
        scope
        |> KitchenRun.open(%{kind: "test_run", actor: :system, input: %{}}, DateTime.utc_now())
        |> Tore.Repo.insert!()
      end

    assert :ok = Runs.fail_interrupted()

    for %{id: id, household_id: hh} <- running do
      assert %KitchenRun{status: :failed, failure_code: :interrupted} =
               Runs.get(Tore.Scope.for_household(hh), id)
    end

    assert Runs.get(scope(), applied.id) == applied
  end
end
