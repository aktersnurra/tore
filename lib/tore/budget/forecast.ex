defmodule Tore.Budget.Forecast do
  @moduledoc """
  Where a week's shop will land, as a ladder of rungs (`Tore.Budget.Forecast.Rung`), each a pure
  function of what Tore knew at a moment (`Tore.Budget.Forecast.Facts`). `backtest/2` says how
  each rung would have done on the weeks already paid for; a rung drives the page only once it
  beats the one below.
  """

  import Ecto.Query

  alias Tore.{Clock, Repo, Scope}
  alias Tore.Budget.Forecast.{Baseline, Facts, OpenDays, Rung}
  alias Tore.Costs.Receipt

  @rungs [Baseline, OpenDays]
  @live OpenDays

  @typedoc """
  A rung's record over the backtest: how many weeks it predicted, its mean absolute error in
  kronor, and the share of weeks whose spend fell in its range (nil for a rung without one).
  """
  @type score :: %{
          weeks: non_neg_integer(),
          mae: Decimal.t() | nil,
          coverage: float() | nil
        }

  @doc "The rungs, lowest first."
  @spec rungs() :: [module()]
  def rungs, do: @rungs

  @doc "The week starting `week_start` as `rung` predicts it from what was known at `as_of`."
  @spec predict(Scope.t(), Date.t(), NaiveDateTime.t(), module()) :: Rung.prediction()
  def predict(%Scope{} = scope, %Date{} = week_start, %NaiveDateTime{} = as_of, rung \\ @live),
    do: rung.predict(Facts.load(scope, week_start, as_of))

  @doc """
  Each rung's score (`t:score/0`) over the finished weeks with receipts, each predicted from what
  Tore knew at the start of its Monday and held against everything paid towards it since.
  `:today` sets which weeks have finished.
  """
  @spec backtest(Scope.t(), keyword()) :: %{module() => score()}
  def backtest(%Scope{} = scope, opts \\ []) do
    today = Keyword.get(opts, :today, Clock.today())

    results =
      for {week, paid} <- paid_weeks(scope, today) do
        facts = Facts.load(scope, week, Clock.utc(NaiveDateTime.new!(week, ~T[00:00:00])))
        {paid, Map.new(@rungs, &{&1, &1.predict(facts)})}
      end

    Map.new(@rungs, fn rung -> {rung, score(for {paid, p} <- results, do: {paid, p[rung]})} end)
  end

  defp paid_weeks(scope, today) do
    from(r in Receipt,
      where: r.week_start < ^Date.add(today, -6),
      group_by: r.week_start,
      order_by: r.week_start,
      select: {r.week_start, sum(r.total_amount)}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Enum.map(fn {week, paid} -> {week, Decimal.new(to_string(paid))} end)
  end

  defp score([]), do: %{weeks: 0, mae: nil, coverage: nil}

  defp score(pairs) do
    n = length(pairs)
    errors = for {paid, p} <- pairs, do: paid |> Decimal.sub(p.expected) |> Decimal.abs()

    ranged =
      for {paid, %{low: %Decimal{} = low, high: %Decimal{} = high}} <- pairs,
          do: {paid, low, high}

    %{
      weeks: n,
      mae: errors |> Enum.reduce(&Decimal.add/2) |> Decimal.div(n) |> Decimal.round(2),
      coverage:
        if(ranged != [],
          do:
            Enum.count(ranged, fn {paid, low, high} ->
              not Decimal.lt?(paid, low) and not Decimal.gt?(paid, high)
            end) / length(ranged)
        )
    }
  end
end
