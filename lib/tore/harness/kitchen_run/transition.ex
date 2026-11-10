defmodule Tore.Harness.KitchenRun.Transition do
  @moduledoc """
  The run's status machine, as a pure function from a run and an action to the columns that
  change. `Runs` writes the changes in the same transaction as any domain change.

  | From         | Action             | To           |
  |--------------|--------------------|--------------|
  | `running`    | `phase`            | `running`    |
  | `running`    | `ask`, `review`    | `needs_user` |
  | `running`    | `apply`            | `applied`    |
  | `running`    | `fail`             | `failed`     |
  | `needs_user` | `confirm`          | `applied`    |
  | `needs_user` | `discard`          | `discarded`  |
  | `applied`    | `revert`           | `reverted`   |

  Anything else is refused. `failed`, `reverted` and `discarded` are terminal. An irreversible
  run can't be reverted.
  """

  alias Tore.Harness.{KitchenRun, Undo}

  @type action ::
          {:phase, atom()}
          | {:ask, String.t()}
          | {:review, String.t()}
          | {:apply, Undo.t()}
          | {:confirm, Undo.t()}
          | {:fail, code :: atom(), message :: String.t() | nil, repair :: term()}
          | {:discard, :user_discarded | :ttl_expired}
          | :revert

  @spec next(KitchenRun.t(), action(), DateTime.t()) ::
          {:ok, map()} | {:error, {:invalid_transition, atom(), atom()} | :irreversible}
  def next(%KitchenRun{status: :running}, {:phase, phase}, _now), do: {:ok, %{phase: phase}}

  def next(%KitchenRun{status: :running}, {action, question}, _now)
      when action in [:ask, :review] and is_binary(question) and question != "" do
    if String.trim(question) == "",
      do: {:error, {:invalid_transition, :running, action}},
      else: {:ok, %{status: :needs_user, question: question, phase: nil}}
  end

  def next(%KitchenRun{status: :running}, {:apply, undo}, now),
    do: {:ok, %{status: :applied, undo: undo, applied_at: now, phase: nil}}

  def next(%KitchenRun{status: :running}, {:fail, code, message, repair}, now) do
    {:ok,
     %{
       status: :failed,
       failure_code: code,
       failure_message: message,
       repair_action: repair,
       closed_at: now,
       phase: nil
     }}
  end

  def next(%KitchenRun{status: :needs_user}, {:confirm, undo}, now),
    do: {:ok, %{status: :applied, undo: undo, applied_at: now}}

  def next(%KitchenRun{status: :needs_user}, {:discard, reason}, now)
      when reason in [:user_discarded, :ttl_expired],
      do: {:ok, %{status: :discarded, discard_reason: reason, closed_at: now}}

  def next(%KitchenRun{status: :applied, undo: undo}, :revert, now) do
    if Undo.reversible?(undo),
      do: {:ok, %{status: :reverted, reverted_at: now}},
      else: {:error, :irreversible}
  end

  def next(%KitchenRun{status: status}, action, _now),
    do: {:error, {:invalid_transition, status, action_name(action)}}

  defp action_name(action) when is_atom(action), do: action
  defp action_name(action) when is_tuple(action), do: elem(action, 0)
end
