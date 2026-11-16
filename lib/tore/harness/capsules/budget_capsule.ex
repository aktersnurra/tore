defmodule Tore.Harness.Capsules.BudgetCapsule do
  @moduledoc """
  The week's budget and what its plan is estimated to cost so far, for the planner. Nothing when
  the week has no budget.
  """

  @behaviour Tore.Harness.Capsule

  alias Tore.{Budget, Planning}

  defstruct [:status]

  @type t :: %__MODULE__{status: Budget.status() | nil}

  @impl true
  def build(%{plan_stream_id: nil}), do: %__MODULE__{}

  def build(%{scope: scope, plan_stream_id: plan_id, week_start: week_start}) do
    case Budget.amount(scope, week_start) do
      nil ->
        %__MODULE__{}

      _budget ->
        {:ok, plan} = Planning.load_plan(scope, plan_id)
        %__MODULE__{status: Budget.status(scope, plan, week_start)}
    end
  end

  @impl true
  def to_prompt(%__MODULE__{status: nil}), do: nil

  def to_prompt(%__MODULE__{status: %{budget: budget, estimate: estimate} = status}) do
    """
    Budget for this week's whole shop: #{kr(budget)} kr. The dinners already planned are \
    estimated at #{kr(estimate.amount)} kr (#{estimate.priced} of #{estimate.total} ingredients \
    priced)#{beyond(status.adjustment)}. Choose dinners so the week stays within the budget: search_recipes gives each \
    recipe's estimated cost, and active_deals shows what's cheap this week. Never change a dinner \
    the household chose or pinned to save money.\
    """
  end

  # What recent weeks paid beyond their dinners' estimates: basics, pack sizes, extras.
  defp beyond(nil), do: ""

  defp beyond(adjustment),
    do: ", and recent weeks paid about #{kr(adjustment)} kr beyond their dinners' estimate"

  defp kr(amount), do: amount |> Decimal.round(0) |> Decimal.to_string()
end
