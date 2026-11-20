defmodule Tore.Budget.Forecast do
  @moduledoc """
  Where a week's shop will land, as a ladder of rungs (`Tore.Budget.Forecast.Rung`), each a pure
  function of what Tore knew at a moment (`Tore.Budget.Forecast.Facts`). `backtest/2` says how
  each rung would have done on the weeks already paid for; a rung drives the page only once it
  beats the one below.
  """

  import Ecto.Query

  alias Tore.{Clock, Repo, Scope}
  alias Tore.Budget.Forecast.{Baseline, Drift, Facts, OpenDays, Rung, ScaleOffset}
  alias Tore.Costs.Receipt

  @rungs [Baseline, OpenDays, ScaleOffset, Drift]
  # Live without a gate: it is what the budget has always gone by.
  @floor OpenDays

  # The gate: over the latest weeks, at least this many, a rung's error must be below the one
  # beneath it and its 80 % range must hold for 70–90 % of them.
  @gate_weeks 12
  @gate_min_weeks 8
  @coverage 70..90

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

  @doc """
  The week starting `week_start` as `rung` predicts it from what was known at `as_of`: the
  open-days rung unless told.
  """
  @spec predict(Scope.t(), Date.t(), NaiveDateTime.t(), module()) :: Rung.prediction()
  def predict(%Scope{} = scope, %Date{} = week_start, %NaiveDateTime{} = as_of, rung \\ @floor),
    do: rung.predict(Facts.load(scope, week_start, as_of))

  @doc """
  The rung the budget page goes by: from the open-days rung up the ladder, each next rung for as
  long as it beats the one below (`beats?/2`) over the latest #{@gate_weeks} finished weeks.
  Takes `backtest/2`'s options.
  """
  @spec live(Scope.t(), keyword()) :: module()
  def live(%Scope{} = scope, opts \\ []) do
    scores = backtest(scope, Keyword.put(opts, :weeks, @gate_weeks))

    @rungs
    |> Enum.drop_while(&(&1 != @floor))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(@floor, fn [below, rung], live ->
      if beats?(scores[rung], scores[below]), do: {:cont, rung}, else: {:halt, live}
    end)
  end

  @doc """
  Whether a rung's score earns it the page over the score of the rung below: over at least
  #{@gate_min_weeks} weeks, a smaller error, and an 80 % range that held for 70–90 % of them.
  """
  @spec beats?(score(), score()) :: boolean()
  def beats?(%{weeks: weeks, mae: mae, coverage: coverage}, %{mae: below}) do
    weeks >= @gate_min_weeks and is_float(coverage) and Decimal.lt?(mae, below) and
      round(coverage * 100) in @coverage
  end

  @doc """
  Each rung's score (`t:score/0`) over the finished weeks with receipts, each predicted from what
  Tore knew at the start of its Monday and held against everything paid towards it since.
  `:today` sets which weeks have finished, `:weeks` keeps only the latest that many.
  """
  @spec backtest(Scope.t(), keyword()) :: %{module() => score()}
  def backtest(%Scope{} = scope, opts \\ []) do
    today = Keyword.get(opts, :today, Clock.today())

    results =
      for {week, paid} <- paid_weeks(scope, today, opts[:weeks]) do
        facts = Facts.load(scope, week, Clock.utc(NaiveDateTime.new!(week, ~T[00:00:00])))
        {paid, Map.new(@rungs, &{&1, &1.predict(facts)})}
      end

    Map.new(@rungs, fn rung -> {rung, score(for {paid, p} <- results, do: {paid, p[rung]})} end)
  end

  defp paid_weeks(scope, today, latest) do
    query =
      from(r in Receipt,
        where: r.week_start < ^Date.add(today, -6),
        group_by: r.week_start,
        order_by: [desc: r.week_start],
        select: {r.week_start, sum(r.total_amount)}
      )

    if(latest, do: limit(query, ^latest), else: query)
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
