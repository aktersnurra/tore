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

  @type status :: %{
          budget: Decimal.t() | nil,
          estimate: Prices.cost(),
          over: Decimal.t() | nil
        }

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

    over =
      if budget && Decimal.gt?(estimate.amount, budget),
        do: Decimal.sub(estimate.amount, budget)

    %{budget: budget, estimate: estimate, over: over}
  end
end
