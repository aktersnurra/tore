defmodule Tore.Budget do
  @moduledoc """
  What a week's shop should cost, and what its plan is estimated to cost.

  A week's budget is its own, set when someone asks to plan to one, or else the household's
  default (`Tore.Household.Preferences`). The estimate is worked out by code from stored prices
  (`Tore.Prices`), never read from a model, and always comes with its coverage. A budget aims the
  planner; it never refuses or replaces anyone's own choice.
  """

  import Ecto.Query

  alias Tore.{Costs, Household, Planning, Prices, Recipes, Repo, Scope, Streams}
  alias Tore.Budget.WeekBudget
  alias Tore.Planning.State

  @typedoc """
  `estimate` is the plan's meals (dinners and any lunches) and due basics at stored prices; `open_days` are the week's
  days with nothing planned, which together cost `open_cost`, a typical dinner each;
  `adjustment` is what recent weeks paid beyond their estimates (nil until two such weeks exist);
  `expected` is all of them together, which is what the budget is held against.
  """
  @type status :: %{
          budget: Decimal.t() | nil,
          estimate: Prices.cost(),
          open_days: 0..7,
          open_cost: Decimal.t(),
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

  @typedoc """
  What the budget page shows for a week: its status, what's been paid towards it and what's left
  by the plan, the eight weeks up to it, the average paid in the weeks before it that had
  receipts, the last four weeks' spending by section, and the latest receipts.
  """
  @type page :: %{
          week_start: Date.t(),
          status: status(),
          paid: Decimal.t(),
          left: Decimal.t(),
          weeks: [
            %{
              week_start: Date.t(),
              paid: Decimal.t() | nil,
              budget: Decimal.t() | nil,
              over?: boolean()
            }
          ],
          average: Decimal.t() | nil,
          sections: list(),
          receipts: [Tore.Costs.Receipt.t()]
        }

  @page_weeks 8
  @section_weeks 4
  @page_receipts 10

  @calibration_weeks 4
  @calibration_min 2
  # A typical dinner is the median of what's cooked this week and in the weeks before it.
  @typical_weeks 4

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

  @doc """
  The meals `plan` cooks, dinners and any lunches: each slot with a recipe that isn't skipped or
  leftovers.
  """
  @spec meals(State.t()) :: [{integer(), pos_integer() | nil}]
  def meals(%State{} = plan), do: for({_key, id, servings} <- cooked(plan), do: {id, servings})

  # Only dinners say what a typical dinner costs, which is what an open day is priced at.
  defp dinners(plan),
    do:
      for(
        {key, id, servings} <- cooked(plan),
        String.ends_with?(key, "_dinner"),
        do: {id, servings}
      )

  defp cooked(%State{slots: slots}) do
    for {key, %{recipe_id: id} = slot} <- slots,
        id != nil,
        !slot[:skipped],
        !slot[:leftover],
        do: {key, id, slot[:servings]}
  end

  @doc """
  What the week starting `week_start` is estimated to cost: `plan`'s meals and the basics due
  (`Tore.Basics`).
  """
  @spec estimate(Scope.t(), State.t(), Date.t()) :: Prices.cost()
  def estimate(%Scope{} = scope, %State{} = plan, %Date{} = week_start) do
    %{meals: meals, basics: basics} = costs(scope, plan, week_start)
    Prices.sum([meals, basics])
  end

  @doc "The week's budget against its plan's estimate, and how far over it is, if it is."
  @spec status(Scope.t(), Date.t()) :: status()
  def status(%Scope{} = scope, %Date{} = week_start) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
    status(scope, plan, week_start)
  end

  @doc """
  As `status/2`, for `plan`. Once calibrated, what's expected is the meals and open days plus
  what recent weeks paid beyond theirs, which already covers basics; before that, the meals, the
  open days and the basics.
  """
  @spec status(Scope.t(), State.t(), Date.t()) :: status()
  def status(%Scope{} = scope, %State{} = plan, %Date{} = week_start) do
    budget = amount(scope, week_start)
    costs = costs(scope, plan, week_start)
    estimate = Prices.sum([costs.meals, costs.basics])
    adjustment = adjustment(scope, week_start)

    expected =
      case adjustment do
        nil -> estimate.amount
        adjustment -> Decimal.add(costs.meals.amount, adjustment)
      end
      |> Decimal.add(costs.open_cost)
      |> Decimal.max(0)
      |> Decimal.round(2)

    over = if budget && Decimal.gt?(expected, budget), do: Decimal.sub(expected, budget)

    %{
      budget: budget,
      estimate: estimate,
      open_days: costs.open_days,
      open_cost: costs.open_cost,
      adjustment: adjustment,
      expected: expected,
      over: over
    }
  end

  @doc "What the budget page shows for the week starting `week_start` (`t:page/0`)."
  @spec page(Scope.t(), Date.t()) :: page()
  def page(%Scope{} = scope, %Date{} = week_start) do
    status = status(scope, week_start)
    first = Date.add(week_start, -7 * (@page_weeks - 1))
    spent = Costs.spent_by_week(scope, first, week_start)
    paid = Map.get(spent, week_start, Decimal.new(0))

    weeks =
      for n <- 0..(@page_weeks - 1), week = Date.add(first, 7 * n) do
        budget = amount(scope, week)
        paid = spent[week]

        %{
          week_start: week,
          paid: paid,
          budget: budget,
          over?: !!(paid && budget && Decimal.gt?(paid, budget))
        }
      end

    before = for {week, paid} <- spent, week != week_start, do: paid

    %{
      week_start: week_start,
      status: status,
      paid: paid,
      left: status.expected |> Decimal.sub(paid) |> Decimal.max(0),
      weeks: weeks,
      average:
        if(before != [],
          do:
            before
            |> Enum.reduce(&Decimal.add/2)
            |> Decimal.div(length(before))
            |> Decimal.round(0)
        ),
      sections:
        Costs.spending_by_section(
          scope,
          Date.add(week_start, -7 * (@section_weeks - 1)),
          week_start
        ),
      receipts: Costs.recent_receipts(scope, @page_receipts)
    }
  end

  # The meals, the due basics and the open days, priced from one lookup.
  defp costs(scope, plan, week_start) do
    meals = meals(plan)
    past = past_dinners(scope, week_start)

    recipes =
      Map.new(
        Recipes.get_many(scope, Enum.uniq(Enum.map(meals ++ past, &elem(&1, 0)))),
        &{&1.id, &1}
      )

    pairs = fn meals ->
      for {id, servings} <- meals, recipe = recipes[id], recipe != nil, do: {recipe, servings}
    end

    meal_ids =
      for {recipe, _} <- pairs.(meals), ri <- recipe.recipe_ingredients, do: ri.ingredient_id

    past_ids =
      for {recipe, _} <- pairs.(past), ri <- recipe.recipe_ingredients, do: ri.ingredient_id

    # A basic the meals already need isn't on the list twice, so it isn't counted twice.
    basics =
      scope
      |> Tore.Basics.lines(week_start)
      |> Enum.reject(&(&1.ingredient_id in meal_ids))

    ids = Enum.uniq(meal_ids ++ past_ids ++ Enum.map(basics, & &1.ingredient_id))
    prices = Prices.for_ingredients(scope, ids, week_start)

    priced = fn meals ->
      Enum.map(pairs.(meals), &Prices.cost(Prices.lines(elem(&1, 0), elem(&1, 1)), prices))
    end

    open_days = open_days(plan, week_start)
    typical = priced.(dinners(plan)) ++ priced.(past)

    open_cost =
      case median(for c <- typical, Decimal.gt?(c.amount, 0), do: c.amount) do
        nil -> Decimal.new(0)
        typical -> typical |> Decimal.mult(open_days) |> Decimal.round(2)
      end

    %{
      meals: Prices.sum(priced.(meals)),
      basics: Prices.cost(basics, prices),
      open_days: open_days,
      open_cost: open_cost
    }
  end

  defp past_dinners(scope, week_start) do
    for weeks_back <- 1..@typical_weeks,
        week = Date.add(week_start, -7 * weeks_back),
        {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week)),
        meal <- dinners(plan),
        do: meal
  end

  # The week's dinners with nothing planned: no recipe, and not eating out, leftovers or skipped.
  defp open_days(plan, week_start) do
    Enum.count(Date.range(week_start, Date.add(week_start, 6)), fn date ->
      case Map.get(plan.slots, Streams.slot_key(date)) do
        nil ->
          true

        slot ->
          slot[:recipe_id] == nil and !slot[:skipped] and !slot[:leftover] and
            !State.eating_out?(slot)
      end
    end)
  end

  defp median([]), do: nil

  defp median(amounts) do
    sorted = Enum.sort(amounts, Decimal)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else:
        Decimal.div(Decimal.add(Enum.at(sorted, div(n, 2) - 1), Enum.at(sorted, div(n, 2))), 2)
  end

  @doc """
  The calibration for the week starting `week_start`: the mean of what was paid minus what its
  meals and open days were estimated at, over the latest #{@calibration_weeks} weeks before it that had a plan and receipts. It
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
      |> Stream.map(fn {week, spent} -> {to_decimal(spent), plan_costs(scope, week)} end)
      |> Stream.reject(fn {_spent, costs} -> Decimal.eq?(costs.meals.amount, 0) end)
      |> Stream.map(fn {spent, costs} ->
        spent |> Decimal.sub(costs.meals.amount) |> Decimal.sub(costs.open_cost)
      end)
      |> Enum.take(@calibration_weeks)

    if length(gaps) >= @calibration_min,
      do: gaps |> Enum.reduce(&Decimal.add/2) |> Decimal.div(length(gaps)) |> Decimal.round(2)
  end

  defp plan_costs(scope, week_start) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
    costs(scope, plan, week_start)
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
