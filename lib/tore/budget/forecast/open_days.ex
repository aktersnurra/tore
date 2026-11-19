defmodule Tore.Budget.Forecast.OpenDays do
  @moduledoc """
  Rung 1, live: as the baseline, but each open dinner costs a typical dinner, in the week and in
  the weeks it calibrates on, so the calibration doesn't count it twice.
  """
  @behaviour Tore.Budget.Forecast.Rung

  alias Tore.Budget.Forecast.{Facts, Rung}

  @impl true
  def predict(%{week: week} = facts) do
    case adjustment(facts) do
      nil -> Decimal.add(week.meals.amount, week.basics.amount)
      adjustment -> Decimal.add(week.meals.amount, adjustment)
    end
    |> Decimal.add(week.open_cost)
    |> Rung.point()
  end

  @doc """
  What recent weeks paid beyond their meals and open days: basics, pack sizes, stock, and
  whatever was bought beyond the plan. Nil until there are enough such weeks.
  """
  @spec adjustment(Facts.t()) :: Decimal.t() | nil
  def adjustment(%{history: history}),
    do:
      Rung.mean_gap(history, fn w ->
        w.paid |> Decimal.sub(w.meals.amount) |> Decimal.sub(w.open_cost)
      end)
end
