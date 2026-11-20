defmodule Tore.Budget.Forecast.Rung do
  @moduledoc """
  One way of predicting what a week's shop will cost, from `Tore.Budget.Forecast.Facts` alone.
  The rungs form a ladder (`.docs/specs/budget-forecast.md`): a rung drives the page only once
  the backtest (`Tore.Budget.Forecast.backtest/2`) shows it beats the one below.

  `low` and `high` bound an 80 % range, or are nil for a rung that gives none. A rung that runs
  the week many times also gives its runs, sorted (`draws`).
  """

  alias Tore.Budget.Forecast.Facts

  @type prediction :: %{
          required(:expected) => Decimal.t(),
          required(:low) => Decimal.t() | nil,
          required(:high) => Decimal.t() | nil,
          optional(:draws) => [float()]
        }

  @callback predict(Facts.t()) :: prediction()

  @calibration_weeks 4
  @calibration_min 2

  @doc """
  The mean of `gap` over the latest #{@calibration_weeks} finished weeks with a priced meal, or
  nil until #{@calibration_min} such weeks exist.
  """
  @spec mean_gap([Facts.finished()], (Facts.finished() -> Decimal.t())) :: Decimal.t() | nil
  def mean_gap(history, gap) do
    gaps =
      history
      |> Enum.reject(&Decimal.eq?(&1.meals.amount, 0))
      |> Enum.take(@calibration_weeks)
      |> Enum.map(gap)

    if length(gaps) >= @calibration_min,
      do: gaps |> Enum.reduce(&Decimal.add/2) |> Decimal.div(length(gaps)) |> Decimal.round(2)
  end

  @doc "An amount in kronor as a float, for the rungs that work in floats."
  @spec to_float(Decimal.t()) :: float()
  def to_float(%Decimal{} = amount), do: Decimal.to_float(amount)

  @doc "A float back in kronor, to the öre."
  @spec to_decimal(float()) :: Decimal.t()
  def to_decimal(amount) when is_float(amount),
    do: amount |> Float.round(2) |> Decimal.from_float()

  @doc "A prediction of `amount`, never below nothing, with no range."
  @spec point(Decimal.t()) :: prediction()
  def point(amount),
    do: %{expected: amount |> Decimal.max(0) |> Decimal.round(2), low: nil, high: nil}
end
