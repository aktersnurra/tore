defmodule Tore.Scope do
  @moduledoc """
  Whose data a call touches. Every context function takes one first, and every query on a household
  table passes its `household_id` to the repo, which refuses the query otherwise (`Tore.Repo`).

  A person's scope comes from their household. Background work that acts for a household, such as a
  run or a cron job, builds one from the household id alone.
  """

  alias Tore.Accounts.User

  @enforce_keys [:household_id]
  defstruct [:household_id, :user_id]

  @type t :: %__MODULE__{household_id: pos_integer(), user_id: pos_integer() | nil}

  @spec for_user(User.t()) :: t()
  def for_user(%User{id: user_id, household_id: household_id}) when is_integer(household_id),
    do: %__MODULE__{household_id: household_id, user_id: user_id}

  @spec for_household(pos_integer()) :: t()
  def for_household(household_id) when is_integer(household_id),
    do: %__MODULE__{household_id: household_id}

  @doc "Repo options that scope a query to this household."
  @spec repo_opts(t()) :: keyword()
  def repo_opts(%__MODULE__{household_id: household_id}), do: [household_id: household_id]
end
