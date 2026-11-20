defmodule Tore.Budget.Forecast.Facts do
  @moduledoc """
  What Tore knew about a week's shop at a moment, `as_of` (a UTC moment): the week's plan priced
  (`t:Tore.Budget.costs/0`), and the finished weeks before it that had receipts, each priced the
  same way with what was paid towards it.

  Rungs (`Tore.Budget.Forecast.Rung`) are pure functions of this struct, so this is the only
  place a forecast reads from, and it never reads what Tore learned after `as_of`: plan events,
  receipts and offers count from when they were stored. What keeps no history is read as it
  stands: the basics and their intervals, the model's price estimates, and which product matched
  which ingredient.
  """

  import Ecto.Query

  alias Tore.{Budget, Clock, Planning, Repo, Scope, Streams}
  alias Tore.Costs.{LineItem, Receipt}
  alias Tore.Prices.Products
  alias Tore.Recipes.Ingredient
  alias Tore.Planning.State

  # Enough finished weeks for the rungs that calibrate on them.
  @history_weeks 8

  defstruct [:week_start, :as_of, :week, :history]

  @typedoc """
  A finished week: its costs as known at `as_of`, what was paid towards it by then, and which
  ingredients its receipts' lines show were bought (nil when they had no lines).
  """
  @type finished :: %{
          required(:week_start) => Date.t(),
          required(:paid) => Decimal.t(),
          required(:bought) => MapSet.t(integer()) | nil,
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          week_start: Date.t(),
          as_of: NaiveDateTime.t(),
          week: Budget.costs(),
          history: [finished()]
        }

  @doc "The facts for the week starting `week_start`, its plan as it stood at `as_of`."
  @spec load(Scope.t(), Date.t(), NaiveDateTime.t()) :: t()
  def load(%Scope{} = scope, %Date{} = week_start, %NaiveDateTime{} = as_of) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start), as_of)
    build(scope, plan, week_start, as_of)
  end

  @doc "As `load/3`, for `plan`: a plan being proposed, or the one as it stands."
  @spec build(Scope.t(), State.t(), Date.t(), NaiveDateTime.t()) :: t()
  def build(%Scope{} = scope, %State{} = plan, %Date{} = week_start, %NaiveDateTime{} = as_of) do
    %__MODULE__{
      week_start: week_start,
      as_of: as_of,
      week: Budget.week_costs(scope, plan, week_start, as_of),
      history: history(scope, week_start, as_of)
    }
  end

  # The latest weeks before this one that had ended by `as_of` and had receipts by then, newest
  # first: one still being shopped for has only part of its receipts.
  defp history(scope, week_start, as_of) do
    this_week = as_of |> Clock.local() |> NaiveDateTime.to_date() |> Streams.monday()
    before = Enum.min([week_start, this_week], Date)

    from(r in Receipt,
      # A receipt without a total says nothing about what was paid.
      where: r.week_start < ^before and r.inserted_at <= ^as_of and not is_nil(r.total_amount),
      group_by: r.week_start,
      order_by: [desc: r.week_start],
      limit: @history_weeks,
      select: {r.week_start, sum(r.total_amount)}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> then(fn weeks ->
      bought = bought(scope, Enum.map(weeks, &elem(&1, 0)), as_of)

      Enum.map(weeks, fn {week, paid} ->
        {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week), as_of)

        scope
        |> Budget.week_costs(plan, week, as_of)
        |> Map.merge(%{week_start: week, paid: to_decimal(paid), bought: bought[week]})
      end)
    end)
  end

  # The ingredients each week's receipts show were bought, by the lines' matches; nil for a week
  # whose receipts had no lines, which says nothing either way.
  defp bought(scope, weeks, as_of) do
    lines =
      from(l in LineItem,
        join: r in Receipt,
        on: r.id == l.receipt_id,
        where: r.week_start in ^weeks and r.inserted_at <= ^as_of,
        select: {r.week_start, l.product_name}
      )
      |> Repo.all(Scope.repo_opts(scope))

    matches = Products.lookup(scope, Enum.uniq(for {_, name} <- lines, do: name))

    for {week, name} <- lines, reduce: %{} do
      acc ->
        id = matches[Ingredient.to_key(name)]
        acc = Map.put_new(acc, week, MapSet.new())
        if id, do: Map.update!(acc, week, &MapSet.put(&1, id)), else: acc
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
end
