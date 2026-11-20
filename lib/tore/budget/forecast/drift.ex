defmodule Tore.Budget.Forecast.Drift do
  @moduledoc """
  Rung 3: what was paid beyond the open days, as a·meals + b, where a and b drift a little from
  week to week. A Kalman filter walks the finished weeks oldest first, so recent weeks count most
  and a household whose shop slowly grows dearer is followed. It starts from the open-days rung
  before calibration (a = 1, b = the basics, loosely), and its variance gives the 80 % range.

  How much a week's spend wanders on its own is guessed at 15 % of what the weeks paid, worth
  four weeks, then measured from how far the filter's own one-week-ahead guesses missed.
  """
  @behaviour Tore.Budget.Forecast.Rung

  import Tore.Budget.Forecast.Rung, only: [to_float: 1, to_decimal: 1]

  # Where a and b start, one standard deviation: the scale around 1, the offset around the
  # basics by this many noise guesses, loose enough for the first weeks to set it.
  @scale_sd 0.25
  @offset_sd 4

  # How far a and b may drift in a week, one standard deviation: the scale by this much, the
  # offset by this share of the noise guess.
  @scale_drift 0.05
  @offset_drift 0.3

  @noise_share 0.15
  @noise_floor 50.0
  @prior_weeks 4

  # An 80 % range is ±z standard deviations.
  @z80 1.2816

  @impl true
  def predict(%{week: week, history: history}) do
    basics = to_float(week.basics.amount)
    {meals, open} = {to_float(week.meals.amount), to_float(week.open_cost)}

    weeks =
      for w <- Enum.reverse(history),
          not Decimal.eq?(w.meals.amount, 0),
          do: {to_float(w.meals.amount), to_float(w.paid) - to_float(w.open_cost)}

    # A share of what a week costs: what the weeks paid, or this one's plan before there are any.
    typical =
      if weeks == [],
        do: meals + basics + open,
        else: Enum.sum(for({_, paid} <- weeks, do: paid)) / length(weeks) + open

    guess = max(@noise_share * typical, @noise_floor)

    # First with the guess, then with what the guesses' misses say the noise is.
    {_, misses} = filter(weeks, basics, guess, guess ** 2)
    noise = (@prior_weeks * guess ** 2 + Enum.sum(misses)) / (@prior_weeks + length(weeks))
    {{state, cov}, _} = filter(weeks, basics, guess, noise)

    {state, cov} = step(state, cov, guess)
    x = [meals, 1.0]
    expected = max(dot(x, state) + open, 0.0)
    half = @z80 * :math.sqrt(dot(x, mul(cov, x)) + noise)

    %{
      expected: to_decimal(expected),
      low: to_decimal(max(expected - half, 0.0)),
      high: to_decimal(expected + half)
    }
  end

  # Walks the weeks, returning where a and b ended up and, for each week, how far its guess
  # missed beyond what the filter already knew it didn't know.
  defp filter(weeks, basics, guess, noise) do
    start = {[1.0, basics], [[@scale_sd ** 2, 0.0], [0.0, (@offset_sd * guess) ** 2]]}

    Enum.map_reduce(weeks, start, fn {meals, paid}, {state, cov} ->
      {state, cov} = step(state, cov, guess)
      x = [meals, 1.0]
      miss = paid - dot(x, state)
      known = dot(x, mul(cov, x))
      gain = Enum.map(mul(cov, x), &(&1 / (known + noise)))

      state = Enum.zip_with(state, gain, &(&1 + &2 * miss))

      cov =
        for {g, row} <- Enum.zip(gain, cov), do: Enum.zip_with(row, mul(cov, x), &(&1 - g * &2))

      {max(miss ** 2 - known, 0.0), {state, cov}}
    end)
    |> then(fn {misses, end_state} -> {end_state, misses} end)
  end

  # A week passes: a and b may have drifted.
  defp step(state, [[aa, ab], [ba, bb]], guess),
    do: {state, [[aa + @scale_drift ** 2, ab], [ba, bb + (@offset_drift * guess) ** 2]]}

  defp dot(a, b), do: a |> Enum.zip_with(b, &(&1 * &2)) |> Enum.sum()
  defp mul(m, v), do: Enum.map(m, &dot(&1, v))
end
