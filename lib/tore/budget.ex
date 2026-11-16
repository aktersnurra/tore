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

  @doc """
  What the week starting `week_start` is estimated to cost: `plan`'s dinners and the basics due
  (`Tore.Basics`).
  """
  @spec estimate(Scope.t(), State.t(), Date.t()) :: Prices.cost()
  def estimate(%Scope{} = scope, %State{} = plan, %Date{} = week_start) do
    %{dinners: dinners, basics: basics} = costs(scope, plan, week_start)
    Prices.sum([dinners, basics])
  end

  @doc "The week's budget against its plan's estimate, and how far over it is, if it is."
  @spec status(Scope.t(), Date.t()) :: status()
  def status(%Scope{} = scope, %Date{} = week_start) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
    status(scope, plan, week_start)
  end

  @doc """
  As `status/2`, for `plan`. Once calibrated, what's expected is the dinners plus what recent weeks
  paid beyond their dinners, which already covers basics; before that, the dinners plus the basics.
  """
  @spec status(Scope.t(), State.t(), Date.t()) :: status()
  def status(%Scope{} = scope, %State{} = plan, %Date{} = week_start) do
    budget = amount(scope, week_start)
    %{dinners: dinners, basics: basics} = costs(scope, plan, week_start)
    estimate = Prices.sum([dinners, basics])
    adjustment = adjustment(scope, week_start)

    expected =
      case adjustment do
        nil -> estimate.amount
        adjustment -> Decimal.add(dinners.amount, adjustment)
      end
      |> Decimal.max(0)
      |> Decimal.round(2)

    over = if budget && Decimal.gt?(expected, budget), do: Decimal.sub(expected, budget)

    %{budget: budget, estimate: estimate, adjustment: adjustment, expected: expected, over: over}
  end

  # The dinners and the due basics, priced from one lookup.
  defp costs(scope, plan, week_start) do
    meals = meals(plan)
    recipes = Map.new(Recipes.get_many(scope, Enum.map(meals, &elem(&1, 0))), &{&1.id, &1})

    pairs =
      for {id, servings} <- meals, recipe = recipes[id], recipe != nil, do: {recipe, servings}

    dinner_ids = for {recipe, _} <- pairs, ri <- recipe.recipe_ingredients, do: ri.ingredient_id

    # A basic the dinners already need isn't on the list twice, so it isn't counted twice.
    basics =
      scope
      |> Tore.Basics.lines(week_start)
      |> Enum.reject(&(&1.ingredient_id in dinner_ids))

    ids = dinner_ids ++ Enum.map(basics, & &1.ingredient_id)

    prices = Prices.for_ingredients(scope, ids, week_start)

    dinners =
      pairs
      |> Enum.map(fn {recipe, servings} ->
        Prices.cost(Prices.lines(recipe, servings), prices)
      end)
      |> Prices.sum()

    %{dinners: dinners, basics: Prices.cost(basics, prices)}
  end

  @doc """
  The calibration for the week starting `week_start`: the mean of what was paid minus what its
  dinners were estimated at, over the latest #{@calibration_weeks} weeks before it that had a plan and receipts. It
  absorbs basics, pack sizes, pantry stock and whatever was bought beyond the plan. Nil until
  #{@calibration_min} such weeks exist.
  """
  @spec adjustment(Scope.t(), Date.t(), Date.t()) :: Decimal.t() | nil
  def adjustment(%Scope{} = scope, %Date{} = week_start, %Date{} = today \\ Tore.Clock.today()) do
    # Only weeks that have ended: one still being shopped for has only part of its receipts.
    before = Enum.min([week_start, Streams.monday(today)], Date)

    gaps =
      from(r in Tore.Costs.Receipt,
        where: r.week_start < ^before,
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
    costs(scope, plan, week_start).dinners.amount
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
