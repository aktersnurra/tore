defmodule Tore.Scope do
  @moduledoc """
  Whose data a call touches. Every context function takes one first, and every query on a household
  table passes its `household_id` to the repo, which refuses the query otherwise (`Tore.Repo`).

  A person's scope comes from their active membership (`Tore.Accounts.get_session/1`). Background work
  that acts for a household, such as a run or a cron job, builds one from the household id alone.
  A call from pi also says which of its sessions it came from (`pi_session`), so a tool can tell a
  person's chat from a background job.
  """

  @enforce_keys [:household_id]
  defstruct [:household_id, :user_id, :pi_session]

  @type t :: %__MODULE__{
          household_id: pos_integer(),
          user_id: pos_integer() | nil,
          pi_session: String.t() | nil
        }

  @spec for_household(pos_integer()) :: t()
  def for_household(household_id) when is_integer(household_id),
    do: %__MODULE__{household_id: household_id}

  @doc "Repo options that scope a query to this household."
  @spec repo_opts(t()) :: keyword()
  def repo_opts(%__MODULE__{household_id: household_id}), do: [household_id: household_id]
end
