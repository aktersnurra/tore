defmodule Tore.Budget.Forecast.ScaleOffset do
  @moduledoc """
  Rung 2: what was paid, as a·meals + b + c·(open days' cost), fitted to the finished weeks by
  least squares and shrunk toward the open-days rung (a = 1, b = its adjustment, c = 1), so a few
  weeks move it only a little. What the fit leaves unexplained, and how unsure it still is of a,
  b and c, give the 80 % range.

  In full: a Bayesian linear regression on how far a, b and c sit from the open-days rung, with a
  normal prior on each; the noise is what the fit leaves unexplained in those weeks, plus a
  guess of 15 % of the week worth four weeks; the range is a Student t on the weeks plus the
  guess.
  """
  @behaviour Tore.Budget.Forecast.Rung

  import Tore.Budget.Forecast.Rung, only: [to_float: 1, to_decimal: 1]

  alias Tore.Budget.Forecast.OpenDays

  # One standard deviation of the prior: how far the meals' scale and the open days' may stray
  # from 1. The offset's is the noise guess.
  @scale_sd 0.25
  @open_sd 0.5

  # The noise guess: a share of the week, never under the floor, worth this many weeks.
  @noise_share 0.15
  @noise_floor 50.0
  @prior_weeks 4

  # Rounds of fitting and re-measuring the noise; it has settled well before this.
  @settle 5

  # Student's t at 90 % by degrees of freedom: an 80 % range is ±t standard deviations. Past the
  # table, the last entry is a little wider than it needs to be.
  @t90 %{
    4 => 1.533,
    5 => 1.476,
    6 => 1.440,
    7 => 1.415,
    8 => 1.397,
    9 => 1.383,
    10 => 1.372,
    11 => 1.363,
    12 => 1.356
  }

  @impl true
  def predict(%{week: week, history: history} = facts) do
    offset = to_float(OpenDays.adjustment(facts) || week.basics.amount)
    x = row(week)

    weeks =
      for w <- history,
          not Decimal.eq?(w.meals.amount, 0),
          do: {row(w), to_float(w.paid) - prior(row(w), offset)}

    n = length(weeks)
    guess = max(@noise_share * prior(x, offset), @noise_floor)

    # The noise is what the fit leaves unexplained, and the fit leans on the weeks by how small
    # the noise is, so the two settle together, starting from the open-days rung's misses.
    {noise, cov, shift} =
      Enum.reduce(1..@settle, {nil, nil, [0.0, 0.0, 0.0]}, fn _, {_, _, shift} ->
        misses = Enum.sum(for {x, y} <- weeks, do: (y - dot(x, shift)) ** 2)
        noise = (@prior_weeks * guess ** 2 + misses) / (@prior_weeks + n)
        cov = inverse(precision(weeks, noise, guess))
        {noise, cov, mul(cov, Enum.map(moment(weeks), &(&1 / noise)))}
      end)

    expected = max(prior(x, offset) + dot(x, shift), 0.0)
    half = @t90[min(@prior_weeks + n, 12)] * :math.sqrt(noise + dot(x, mul(cov, x)))

    %{
      expected: to_decimal(expected),
      low: to_decimal(max(expected - half, 0.0)),
      high: to_decimal(expected + half)
    }
  end

  # How sure the fit is of a, b and c: the prior's precision plus what the weeks say.
  defp precision(weeks, noise, guess) do
    for {row, i} <- Enum.with_index(gram(weeks)) do
      for {v, j} <- Enum.with_index(row) do
        v / noise + if(i == j, do: 1 / Enum.at([@scale_sd, guess, @open_sd], i) ** 2, else: 0)
      end
    end
  end

  # A week as what a, b and c multiply.
  defp row(w), do: [to_float(w.meals.amount), 1.0, to_float(w.open_cost)]

  # The open-days rung's prediction for a row.
  defp prior([meals, _, open], offset), do: meals + offset + open

  defp gram(weeks) do
    for i <- 0..2 do
      for j <- 0..2, do: Enum.sum(for {x, _} <- weeks, do: Enum.at(x, i) * Enum.at(x, j))
    end
  end

  defp moment(weeks), do: for(i <- 0..2, do: Enum.sum(for {x, y} <- weeks, do: Enum.at(x, i) * y))

  defp dot(a, b), do: a |> Enum.zip_with(b, &(&1 * &2)) |> Enum.sum()
  defp mul(m, v), do: Enum.map(m, &dot(&1, v))

  defp inverse([[a, b, c], [d, e, f], [g, h, i]]) do
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)

    for row <- [
          [e * i - f * h, c * h - b * i, b * f - c * e],
          [f * g - d * i, a * i - c * g, c * d - a * f],
          [d * h - e * g, b * g - a * h, a * e - b * d]
        ],
        do: Enum.map(row, &(&1 / det))
  end
end
