defmodule Tore.Budget.Forecast.PerLine do
  @moduledoc """
  Rung 4: the week line by line. Each ingredient on the list counts at its price times the
  chance it gets bought, learned from the finished weeks whose receipts had lines: how often it
  was bought when it was on the list, pulled toward how often the household buys what's on its
  list, and that pulled toward always until there is evidence. On top come the extras, what
  recent weeks paid beyond their list as this rung sees it (what wasn't on the list, pack sizes,
  prices that moved), and the open days.

  The 80 % range comes from whether each line is bought and from how much the extras vary.
  Product matches keep no history, so a backtest reads which ingredient a line was as it stands.
  """
  @behaviour Tore.Budget.Forecast.Rung

  # Weeks' worth of pull: an ingredient's chance toward the household's, the household's toward 1.
  @pull 2

  @extras_weeks 4
  @extras_min 2

  # The extras' spread is guessed at this share of the week, worth this many weeks.
  @noise_share 0.15
  @noise_floor 50.0
  @prior_weeks 4

  # An 80 % range is ±z standard deviations.
  @z80 1.2816

  @impl true
  def predict(%{week: week, history: history}) do
    chance = chances(history)
    list = fn w -> Enum.sum(for {id, kr} <- w.lines, do: chance.(id) * to_float(kr)) end

    extras =
      history
      |> Enum.reject(&Decimal.eq?(&1.meals.amount, 0))
      |> Enum.take(@extras_weeks)
      |> Enum.map(&(to_float(&1.paid) - list.(&1) - to_float(&1.open_cost)))

    n = length(extras)
    extra = if n >= @extras_min, do: Enum.sum(extras) / n, else: 0.0
    expected = max(list.(week) + extra + to_float(week.open_cost), 0.0)

    guess = max(@noise_share * expected, @noise_floor)
    spread = if n >= @extras_min, do: Enum.sum(for e <- extras, do: (e - extra) ** 2), else: 0.0
    extras_var = (@prior_weeks * guess ** 2 + spread) / (@prior_weeks + max(n - 1, 0))

    lines_var =
      Enum.sum(for {id, kr} <- week.lines, p = chance.(id), do: p * (1 - p) * to_float(kr) ** 2)

    half = @z80 * :math.sqrt(lines_var + extras_var * (1 + 1 / max(n, 1)))

    %{
      expected: to_decimal(expected),
      low: to_decimal(max(expected - half, 0.0)),
      high: to_decimal(expected + half)
    }
  end

  # The chance an ingredient on the list is bought.
  defp chances(history) do
    counts =
      for %{bought: %MapSet{} = bought, lines: lines} <- history,
          {id, _} <- lines,
          reduce: %{} do
        acc ->
          hit = if MapSet.member?(bought, id), do: 1, else: 0
          Map.update(acc, id, {hit, 1}, fn {k, n} -> {k + hit, n + 1} end)
      end

    {hits, listed} =
      Enum.reduce(Map.values(counts), {0, 0}, fn {k, n}, {hits, listed} ->
        {hits + k, listed + n}
      end)

    household = (hits + @pull) / (listed + @pull)

    fn id ->
      {k, n} = Map.get(counts, id, {0, 0})
      (k + @pull * household) / (n + @pull)
    end
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_decimal(f), do: f |> Float.round(2) |> Decimal.from_float()
end
