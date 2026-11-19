defmodule Tore.Budget.Forecast.Baseline do
  @moduledoc """
  Rung 0: the plan's meals plus what recent weeks paid beyond their meals, or the meals and the
  basics before that is known. An open day costs nothing.
  """
  @behaviour Tore.Budget.Forecast.Rung

  alias Tore.Budget.Forecast.Rung

  @impl true
  def predict(%{week: week, history: history}) do
    case Rung.mean_gap(history, &Decimal.sub(&1.paid, &1.meals.amount)) do
      nil -> Rung.point(Decimal.add(week.meals.amount, week.basics.amount))
      offset -> Rung.point(Decimal.add(week.meals.amount, offset))
    end
  end
end
