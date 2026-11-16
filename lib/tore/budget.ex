defmodule Tore.Budget do
  @moduledoc """
  What a week's shop should cost, and what its plan is estimated to cost.

  A week's budget is its own, set when someone asks to plan to one, or else the household's
  default (`Tore.Household.Preferences`). The estimate is worked out by code from stored prices
  (`Tore.Prices`), never read from a model, and always comes with its coverage. A budget aims the
  planner; it never refuses or replaces anyone's own choice.
  """

  import Ecto.Query

  alias Tore.{Household, Planning, Prices, Recipes, Repo, Scope, Streams}
  alias Tore.Budget.WeekBudget
  alias Tore.Planning.State

  @typedoc """
  `estimate` is the plan's dinners at stored prices; `adjustment` is what recent weeks paid beyond
  their estimates (nil until two such weeks exist); `expected` is the two together, which is what
  the budget is held against.
  """
  @type status :: %{
          budget: Decimal.t() | nil,
          estimate: Prices.cost(),
          adjustment: Decimal.t() | nil,
          expected: Decimal.t(),
          over: Decimal.t() | nil
        }

  @type verdict :: %{
          spent: Decimal.t(),
          budget: Decimal.t() | nil,
          expected: Decimal.t(),
          off_by_percent: integer() | nil
        }

  @calibration_weeks 4
  @calibration_min 2

  @doc "The week's budget: its own, else the household's default, else none."
  @spec amount(Scope.t(), Date.t()) :: Decimal.t() | nil
  def amount(%Scope{} = scope, %Date{} = week_start) do
    case Repo.get_by(WeekBudget, [week_start: week_start], Scope.repo_opts(scope)) do
      %WeekBudget{amount: amount} -> amount
      nil -> Household.get_preferences(scope).weekly_budget
    end
  end

  @doc "Sets the week's own budget; nil goes back to the default."
  @spec set_week(Scope.t(), Date.t(), Decimal.t() | nil) :: :ok | {:error, :invalid_amount}
  def set_week(%Scope{} = scope, %Date{} = week_start, nil) do
    Repo.delete_all(
      from(b in WeekBudget, where: b.week_start == ^week_start),
      Scope.repo_opts(scope)
    )

    :ok
  end

  def set_week(%Scope{} = scope, %Date{} = week_start, %Decimal{} = amount) do
    if Decimal.gt?(amount, 0) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert!(
        %WeekBudget{
          household_id: scope.household_id,
          week_start: Streams.monday(week_start),
          amount: amount,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: [set: [amount: amount, updated_at: now]],
        conflict_target: [:household_id, :week_start]
      )

      :ok
    else
      {:error, :invalid_amount}
    end
  end

  @doc "Sets the household's default weekly budget; nil means none."
  @spec set_default(Scope.t(), Decimal.t() | nil) :: :ok | {:error, Ecto.Changeset.t()}
  def set_default(%Scope{} = scope, amount) do
    with {:ok, _} <- Household.update_preferences(scope, %{weekly_budget: amount}), do: :ok
  end

  @doc "The dinners `plan` cooks: each slot with a recipe that isn't skipped or leftovers."
  @spec meals(State.t()) :: [{integer(), pos_integer() | nil}]
  def meals(%State{slots: slots}) do
    for {_key, %{recipe_id: id} = slot} <- slots,
        id != nil,
        !slot[:skipped],
        !slot[:leftover],
        do: {id, slot[:servings]}
  end

  @doc "What `plan` for the week starting `week_start` is estimated to cost."
  @spec estimate(Scope.t(), State.t(), Date.t()) :: Prices.cost()
  def estimate(%Scope{} = scope, %State{} = plan, %Date{} = week_start) do
    meals = meals(plan)
    recipes = Map.new(Recipes.get_many(scope, Enum.map(meals, &elem(&1, 0))), &{&1.id, &1})

    pairs =
      for {id, servings} <- meals, recipe = recipes[id], recipe != nil, do: {recipe, servings}

    ids = for {recipe, _} <- pairs, ri <- recipe.recipe_ingredients, do: ri.ingredient_id
    prices = Prices.for_ingredients(scope, ids, week_start)

    pairs
    |> Enum.map(fn {recipe, servings} -> Prices.cost(Prices.lines(recipe, servings), prices) end)
    |> Prices.sum()
  end

  @doc "The week's budget against its plan's estimate, and how far over it is, if it is."
  @spec status(Scope.t(), Date.t()) :: status()
  def status(%Scope{} = scope, %Date{} = week_start) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
    status(scope, plan, week_start)
  end

  @spec status(Scope.t(), State.t(), Date.t()) :: status()
  def status(%Scope{} = scope, %State{} = plan, %Date{} = week_start) do
    budget = amount(scope, week_start)
    estimate = estimate(scope, plan, week_start)
    adjustment = adjustment(scope, week_start)
    expected = Decimal.add(estimate.amount, adjustment || 0) |> Decimal.max(0) |> Decimal.round(2)

    over = if budget && Decimal.gt?(expected, budget), do: Decimal.sub(expected, budget)

    %{budget: budget, estimate: estimate, adjustment: adjustment, expected: expected, over: over}
  end

  @doc """
  The calibration for the week starting `week_start`: the mean of what was paid minus what was
  estimated, over the latest #{@calibration_weeks} weeks before it that had a plan and receipts. It
  absorbs pack sizes, pantry stock and whatever was bought beyond the plan. Nil until
  #{@calibration_min} such weeks exist.
  """
  @spec adjustment(Scope.t(), Date.t()) :: Decimal.t() | nil
  def adjustment(%Scope{} = scope, %Date{} = week_start) do
    gaps =
      from(r in Tore.Costs.Receipt,
        where: r.week_start < ^week_start,
        group_by: r.week_start,
        order_by: [desc: r.week_start],
        select: {r.week_start, sum(r.total_amount)}
      )
      |> Repo.all(Scope.repo_opts(scope))
      |> Stream.map(fn {week, spent} -> {to_decimal(spent), plan_estimate(scope, week)} end)
      |> Stream.reject(fn {_spent, estimate} -> Decimal.eq?(estimate, 0) end)
      |> Stream.map(fn {spent, estimate} -> Decimal.sub(spent, estimate) end)
      |> Enum.take(@calibration_weeks)

    if length(gaps) >= @calibration_min,
      do: gaps |> Enum.reduce(&Decimal.add/2) |> Decimal.div(length(gaps)) |> Decimal.round(2)
  end

  defp plan_estimate(scope, week_start) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
    estimate(scope, plan, week_start).amount
  end

  @doc """
  How the week went, once it has ended and something was paid towards it: what was spent, the
  budget, what was expected, and how far the spend was from that, in percent. Nil otherwise: no
  receipt and no typed total means no verdict.
  """
  @spec verdict(Scope.t(), Date.t(), Date.t()) :: verdict() | nil
  def verdict(%Scope{} = scope, %Date{} = week_start, %Date{} = today \\ Tore.Clock.today()) do
    with true <- Date.compare(Date.add(week_start, 6), today) == :lt,
         %Decimal{} = spent <- Tore.Costs.spent_in_week(scope, week_start) do
      %{expected: expected, budget: budget} = status(scope, week_start)

      %{
        spent: spent,
        budget: budget,
        expected: expected,
        off_by_percent:
          if(Decimal.gt?(expected, 0),
            do:
              spent
              |> Decimal.sub(expected)
              |> Decimal.mult(100)
              |> Decimal.div(expected)
              |> Decimal.round(0)
              |> Decimal.to_integer()
          )
      }
    else
      _ -> nil
    end
  end

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
end
