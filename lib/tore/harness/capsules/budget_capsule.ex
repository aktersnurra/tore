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

  def to_prompt(%__MODULE__{
        status: %{budget: budget, estimate: estimate, expected: expected} = s
      }) do
    """
    Budget for this week's whole shop: #{kr(budget)} kr. With the dinners already planned, the \
    week is expected to cost about #{kr(expected)} kr, everyday extras included#{open(s)} \
    (#{estimate.priced} of #{estimate.total} ingredients have a real price). Choose dinners so the \
    week stays within the budget: search_recipes gives each recipe's estimated cost, and \
    active_deals shows what's cheap this week. Never change a dinner the household chose or \
    pinned to save money.\
    """
  end

  # Said only once a typical dinner has a price; until then open days add nothing.
  defp open(%{open_days: days, open_cost: cost}) do
    if Decimal.gt?(cost, 0),
      do: " and #{days} open days at a typical dinner, #{kr(cost)} kr together",
      else: ""
  end

  defp kr(amount), do: amount |> Decimal.round(0) |> Decimal.to_string()
end
