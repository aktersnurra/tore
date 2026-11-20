defmodule Tore.Budget do
  @moduledoc """
  What a week's shop should cost, and what its plan is estimated to cost.

  A week's budget is its own, set when someone asks to plan to one, or else the household's
  budget from the latest change on or before it (`Tore.Budget.BudgetChange`), so raising it from
  week 41 leaves the weeks before at what they had. A household's first budget also covers the
  weeks before it. The estimate is worked out by code from stored prices
  (`Tore.Prices`), never read from a model, and always comes with its coverage. A budget aims the
  planner; it never refuses or replaces anyone's own choice.
  """

  import Ecto.Query

  alias Tore.{Costs, Planning, Prices, Recipes, Repo, Scope, Streams}
  alias Tore.Budget.{BudgetChange, WeekBudget}
  alias Tore.Budget.Forecast.{Facts, OpenDays}
  alias Tore.Planning.State

  @typedoc """
  `estimate` is the plan's meals (dinners and any lunches) and due basics at stored prices; `open_days` are the week's
  days with nothing planned, which together cost `open_cost`, a typical dinner each;
  `adjustment` is what recent weeks paid beyond their estimates (nil until two such weeks exist);
  `expected` is where the forecast rung says the week lands, which is what the budget is held
  against, and `low` and `high` its 80 % range, nil for a rung without one; `risk` is the share of
  a simulating rung's runs that went over the budget, nil without a budget or such a rung.
  """
  @type status :: %{
          budget: Decimal.t() | nil,
          estimate: Prices.cost(),
          open_days: 0..7,
          open_cost: Decimal.t(),
          adjustment: Decimal.t() | nil,
          expected: Decimal.t(),
          low: Decimal.t() | nil,
          high: Decimal.t() | nil,
          risk: float() | nil,
          over: Decimal.t() | nil
        }

  @typedoc """
  A week's plan priced as Tore knew it at a moment: its meals and the basics due, what each
  ingredient on that list costs, how many dinners are open, what this week's and recent weeks'
  priced dinners cost, a typical dinner (their median, nil while none has a price), and the open
  days at it.
  """
  @type costs :: %{
          meals: Prices.cost(),
          basics: Prices.cost(),
          lines: %{integer() => Decimal.t()},
          open_days: 0..7,
          dinner_costs: [Decimal.t()],
          typical: Decimal.t() | nil,
          open_cost: Decimal.t()
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

  # A typical dinner is the median of what's cooked this week and in the weeks before it.
  @typical_weeks 4

  @doc """
  The week's budget: its own, else the latest change on or before it, else the household's first
  change, else none.
  """
  @spec amount(Scope.t(), Date.t()) :: Decimal.t() | nil
  def amount(%Scope{} = scope, %Date{} = week_start) do
    case Repo.get_by(WeekBudget, [week_start: week_start], Scope.repo_opts(scope)) do
      %WeekBudget{amount: amount} -> amount
      nil -> standing(scope, week_start)
    end
  end

  defp standing(scope, week_start) do
    latest =
      from(c in BudgetChange,
        where: c.from_week <= ^week_start,
        order_by: [desc: c.from_week],
        limit: 1,
        select: c.amount
      )

    first =
      from(c in BudgetChange, order_by: [asc: c.from_week], limit: 1, select: c.amount)

    case Repo.all(latest, Scope.repo_opts(scope)) do
      [amount] -> amount
      [] -> Repo.one(first, Scope.repo_opts(scope))
    end
  end

  @doc "Sets the household's budget from the week of `date` on; nil is no budget from then."
  @spec set_from(Scope.t(), Date.t(), Decimal.t() | nil) :: :ok | {:error, :invalid_amount}
  def set_from(%Scope{} = scope, %Date{} = date, amount) do
    if amount == nil or Decimal.gt?(amount, 0) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert!(
        %BudgetChange{
          household_id: scope.household_id,
          from_week: Streams.monday(date),
          amount: amount,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: [set: [amount: amount, updated_at: now]],
        conflict_target: [:household_id, :from_week]
      )

      :ok
    else
      {:error, :invalid_amount}
    end
  end

  @doc "Sets the week's own budget; nil goes back to the household's."
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
    %{meals: meals, basics: basics} = week_costs(scope, plan, week_start)
    Prices.sum([meals, basics])
  end

  @doc "The week's budget against its plan's estimate, and how far over it is, if it is."
  @spec status(Scope.t(), Date.t()) :: status()
  def status(%Scope{} = scope, %Date{} = week_start) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
    status(scope, plan, week_start)
  end

  @doc """
  As `status/2`, for `plan`, predicted by the forecast rung `rung` (`Tore.Budget.Forecast`). By
  default that is the open-days rung (`Tore.Budget.Forecast.OpenDays`): once calibrated, the
  meals and open days plus what recent weeks paid beyond theirs, which already covers basics;
  before that, the meals, the open days and the basics. Never below what has been paid towards
  the week already: a big shop early in the week moves the week up, not the paid part down.
  """
  @spec status(Scope.t(), State.t(), Date.t(), module()) :: status()
  def status(%Scope{} = scope, %State{} = plan, %Date{} = week_start, rung \\ OpenDays) do
    budget = amount(scope, week_start)
    {facts, prediction} = predict(scope, plan, week_start, rung)
    paid = Map.get(Costs.spent_by_week(scope, week_start, week_start), week_start, Decimal.new(0))
    at_least_paid = fn amount -> amount && Decimal.max(amount, paid) end
    expected = at_least_paid.(prediction.expected)
    {low, high} = {at_least_paid.(prediction.low), at_least_paid.(prediction.high)}
    over = if budget && Decimal.gt?(expected, budget), do: Decimal.sub(expected, budget)

    risk =
      with %Decimal{} <- budget, [_ | _] = draws <- prediction[:draws] do
        limit = Decimal.to_float(budget)
        floor = Decimal.to_float(paid)
        Enum.count(draws, &(max(&1, floor) > limit)) / length(draws)
      else
        _ -> nil
      end

    %{
      budget: budget,
      estimate: Prices.sum([facts.week.meals, facts.week.basics]),
      open_days: facts.week.open_days,
      open_cost: facts.week.open_cost,
      adjustment: OpenDays.adjustment(facts),
      expected: expected,
      low: low,
      high: high,
      risk: risk,
      over: over
    }
  end

  # What `rung` predicts the week costs from its plan alone, with the facts it was given.
  defp predict(scope, plan, week_start, rung) do
    facts = Facts.build(scope, plan, week_start, NaiveDateTime.utc_now())
    {facts, rung.predict(facts)}
  end

  @doc """
  What the budget page shows for the week starting `week_start` (`t:page/0`), its status
  predicted by `rung` (`status/4`).
  """
  @spec page(Scope.t(), Date.t(), module()) :: page()
  def page(%Scope{} = scope, %Date{} = week_start, rung \\ OpenDays) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
    status = status(scope, plan, week_start, rung)
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

  @doc """
  `plan`'s meals, the due basics and the open days in the week starting `week_start`, priced from
  one lookup of what Tore knew at `as_of` (a UTC moment; `t:costs/0`).
  """
  @spec week_costs(Scope.t(), State.t(), Date.t(), NaiveDateTime.t()) :: costs()
  def week_costs(scope, plan, week_start, as_of \\ NaiveDateTime.utc_now()) do
    meals = meals(plan)
    past = past_dinners(scope, week_start, as_of)

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
    prices = Prices.for_ingredients(scope, ids, week_start, as_of)

    priced = fn meals ->
      Enum.map(pairs.(meals), &Prices.cost(Prices.lines(elem(&1, 0), elem(&1, 1)), prices))
    end

    open_days = open_days(plan, week_start)

    dinner_costs =
      for c <- priced.(dinners(plan)) ++ priced.(past), Decimal.gt?(c.amount, 0), do: c.amount

    typical = median(dinner_costs)

    lines =
      for {recipe, servings} <- pairs.(meals), line <- Prices.lines(recipe, servings) do
        line
      end

    %{
      meals: Prices.sum(priced.(meals)),
      basics: Prices.cost(basics, prices),
      lines: line_costs(lines ++ basics, prices),
      open_days: open_days,
      dinner_costs: dinner_costs,
      typical: typical,
      open_cost:
        if(typical,
          do: typical |> Decimal.mult(open_days) |> Decimal.round(2),
          else: Decimal.new(0)
        )
    }
  end

  # What each ingredient on the list costs, its lines together; unpriced lines are left out.
  defp line_costs(lines, prices) do
    for line <- lines,
        {_source, amount} <- [Prices.line_cost(line, Map.get(prices, line.ingredient_id, %{}))],
        reduce: %{} do
      acc -> Map.update(acc, line.ingredient_id, amount, &Decimal.add(&1, amount))
    end
  end

  defp past_dinners(scope, week_start, as_of) do
    for weeks_back <- 1..@typical_weeks,
        week = Date.add(week_start, -7 * weeks_back),
        {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week), as_of),
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
  How the week went, once it has ended and something was paid towards it: what was spent, the
  budget, what the plan was expected to cost (before what was paid, unlike `status/4`), and how
  far the spend was from that, in percent. Nil otherwise: no
  receipt and no typed total means no verdict.
  """
  @spec verdict(Scope.t(), Date.t(), Date.t()) :: verdict() | nil
  def verdict(%Scope{} = scope, %Date{} = week_start, %Date{} = today \\ Tore.Clock.today()) do
    with true <- Date.compare(Date.add(week_start, 6), today) == :lt,
         %Decimal{} = spent <- Tore.Costs.spent_in_week(scope, week_start) do
      {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week_start))
      {_facts, %{expected: expected}} = predict(scope, plan, week_start, OpenDays)
      budget = amount(scope, week_start)

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
end
