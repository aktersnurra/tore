defmodule Tore.Harness.KitchenRun.TransitionTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.KitchenRun
  alias Tore.Harness.KitchenRun.Transition

  @now ~U[2026-11-10 12:00:00.000000Z]
  @undo {:steps, [{:delete_receipt, 1}]}

  @actions [
    {:phase, :proposing},
    {:ask, "Which day?"},
    {:review, "Review the receipt."},
    {:apply, @undo},
    {:confirm, @undo},
    {:fail, :internal_error, nil, nil},
    {:discard, :user_discarded},
    :revert
  ]

  @legal %{
    running: [:phase, :ask, :review, :apply, :fail],
    needs_user: [:confirm, :discard],
    applied: [:revert],
    failed: [],
    reverted: [],
    discarded: []
  }

  defp name(action) when is_atom(action), do: action
  defp name(action), do: elem(action, 0)

  test "every status and action pair is either the table's move or refused" do
    for {status, legal} <- @legal, action <- @actions do
      run = %KitchenRun{status: status, undo: @undo}

      if name(action) in legal do
        assert {:ok, _changes} = Transition.next(run, action, @now), "#{status} #{name(action)}"
      else
        assert Transition.next(run, action, @now) ==
                 {:error, {:invalid_transition, status, name(action)}}
      end
    end
  end

  test "each move sets what the row's constraints require" do
    running = %KitchenRun{status: :running, phase: :proposing}

    assert {:ok, %{status: :needs_user, question: "Which day?", phase: nil}} =
             Transition.next(running, {:ask, "Which day?"}, @now)

    assert {:ok, %{status: :applied, undo: @undo, applied_at: @now, phase: nil}} =
             Transition.next(running, {:apply, @undo}, @now)

    assert {:ok, %{status: :failed, failure_code: :slot_pinned, closed_at: @now}} =
             Transition.next(
               running,
               {:fail, :slot_pinned, nil, {:edit_plan, ["mon_dinner"]}},
               @now
             )

    needs_user = %KitchenRun{status: :needs_user, question: "Review"}

    assert {:ok, %{status: :applied, undo: @undo, applied_at: @now}} =
             Transition.next(needs_user, {:confirm, @undo}, @now)

    assert {:ok, %{status: :discarded, discard_reason: :ttl_expired, closed_at: @now}} =
             Transition.next(needs_user, {:discard, :ttl_expired}, @now)

    assert {:ok, %{status: :reverted, reverted_at: @now}} =
             Transition.next(%KitchenRun{status: :applied, undo: @undo}, :revert, @now)
  end

  test "an irreversible run can't be reverted" do
    run = %KitchenRun{status: :applied, undo: {:irreversible, "receipt photo is gone"}}
    assert Transition.next(run, :revert, @now) == {:error, :irreversible}
  end

  test "a blank question is refused, since a waiting run must say what it waits for" do
    assert {:error, _} = Transition.next(%KitchenRun{status: :running}, {:ask, "  "}, @now)
    assert {:error, _} = Transition.next(%KitchenRun{status: :running}, {:review, ""}, @now)
  end

  test "a discard needs a known reason" do
    assert {:error, {:invalid_transition, :needs_user, :discard}} =
             Transition.next(%KitchenRun{status: :needs_user}, {:discard, :bored}, @now)
  end
end
