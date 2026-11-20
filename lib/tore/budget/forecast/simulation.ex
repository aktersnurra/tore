defmodule Tore.Budget.Forecast.Simulation do
  @moduledoc """
  Rung 5: the week run 2000 times. In each run every ingredient on the list is bought or not at
  the per-line rung's chance (`Tore.Budget.Forecast.PerLine`), each open day costs one of this
  and recent weeks' dinners picked at random, and the extras come out around their recent mean.

  The runs' mean is the expectation. Their spread is then calibrated against the finished weeks
  (split conformal): each week is run the same way, and the spread is widened or narrowed until
  80 % of those weeks would have landed in its 10th–90th percentile. The calibrated runs give the
  range, and the share of them above a budget the risk of going over it (`:draws`).

  The runs are seeded from the facts, so the same facts always give the same answer, whenever
  they are read.
  """
  @behaviour Tore.Budget.Forecast.Rung

  alias Tore.Budget.Forecast.PerLine

  @runs 2000
  @calibration_weeks 8
  @calibration_min 4
  @z80 1.2816

  @impl true
  def predict(%{week: week, history: history} = facts) do
    chance = PerLine.chances(history)
    # Not the moment the facts were read at, or every load would run differently.
    seed = :rand.seed_s(:exsss, {:erlang.phash2(%{facts | as_of: nil}), 7, 11})

    {draws, seed} = run(week, history, chance, seed)
    mean = Enum.sum(draws) / @runs
    widen = widen(history, chance, seed)

    calibrated =
      draws
      |> Enum.map(&max(mean + widen * (&1 - mean), 0.0))
      |> Enum.sort()

    %{
      expected: to_decimal(max(mean, 0.0)),
      low: to_decimal(percentile(calibrated, 0.1)),
      high: to_decimal(percentile(calibrated, 0.9)),
      draws: calibrated
    }
  end

  # The week's shop, `@runs` times.
  defp run(week, history, chance, seed) do
    {extra, extras_var} = PerLine.extras(week, history, chance)
    lines = for {id, kr} <- week.lines, do: {chance.(id), to_float(kr)}
    dinners = Enum.map(week.dinner_costs, &to_float/1) |> List.to_tuple()

    Enum.map_reduce(1..@runs, seed, fn _, seed ->
      {list, seed} =
        Enum.reduce(lines, {0.0, seed}, fn {p, kr}, {sum, seed} ->
          {u, seed} = :rand.uniform_s(seed)
          {if(u < p, do: sum + kr, else: sum), seed}
        end)

      {open, seed} =
        Enum.reduce(1..week.open_days//1, {0.0, seed}, fn _, {sum, seed} ->
          if tuple_size(dinners) == 0 do
            {sum, seed}
          else
            {i, seed} = :rand.uniform_s(tuple_size(dinners), seed)
            {sum + elem(dinners, i - 1), seed}
          end
        end)

      {z, seed} = :rand.normal_s(seed)
      {list + open + extra + z * :math.sqrt(extras_var), seed}
    end)
  end

  # How much the runs' spread must stretch for its 80 % to have held 80 % of the finished weeks:
  # each week's miss in its own runs' standard deviations, the conformal quantile of those, over
  # what a normal spread would need. As it is until there are enough weeks.
  defp widen(history, chance, seed) do
    scores =
      history
      |> Enum.reject(&Decimal.eq?(&1.meals.amount, 0))
      |> Enum.take(@calibration_weeks)
      |> Enum.map_reduce(seed, fn w, seed ->
        {draws, seed} = run(w, history, chance, seed)
        mean = Enum.sum(draws) / @runs
        sd = :math.sqrt(Enum.sum(for d <- draws, do: (d - mean) ** 2) / @runs)
        {abs(to_float(w.paid) - mean) / max(sd, 1.0), seed}
      end)
      |> elem(0)
      |> Enum.sort()

    n = length(scores)

    if n >= @calibration_min,
      do: Enum.at(scores, min(ceil((n + 1) * 0.8), n) - 1) / @z80,
      else: 1.0
  end

  defp percentile(sorted, p), do: Enum.at(sorted, floor(p * (length(sorted) - 1)))

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_decimal(f), do: f |> Float.round(2) |> Decimal.from_float()
end
