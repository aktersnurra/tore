defmodule Tore.BudgetFixtures do
  @moduledoc """
  Finished weeks for the budget forecast: a dinner each, eating out the other days so no day is
  open, paid the way the household pays.
  """

  import Ecto.Query
  import Tore.AccountsFixtures

  alias Tore.{Planning, Recipes, Repo, Scope, Streams}
  alias Tore.Costs.Receipt
  alias Tore.EventStore.Event

  @doc "A recipe for 4 whose one ingredient is estimated at `kr` per item."
  def priced_recipe(scope, title, kr) do
    {:ok, recipe} =
      Recipes.create(
        scope,
        %{
          title: title,
          recipe_type: :meal,
          base_servings: 4,
          ingredients: [%{name: title <> " i", quantity: 1, unit: "st"}]
        }
      )

    Repo.update_all(
      from(i in Recipes.Ingredient, where: i.name == ^(title <> " i")),
      [set: [estimated_price: Decimal.new(kr), estimated_unit: "st"]],
      Scope.repo_opts(scope)
    )

    recipe
  end

  @doc "The week starting `week` plans Monday's `dinner` and eats out the rest."
  def one_dinner(scope, week, dinner) do
    plan = Streams.plan(scope, week)
    {:ok, _} = Planning.assign_recipe(scope, plan, "mon_dinner", dinner.id, 4)

    for day <- ~w(tue wed thu fri sat sun) do
      {:ok, _} = Planning.eat_out(scope, plan, day <> "_dinner", %{})
    end

    :ok
  end

  @doc """
  Sixteen weeks for `scaled_weeks/3` that pay what scale and offset expects give or take up to
  80 kr: enough for it to beat open days at the gate (`Tore.Budget.Forecast.beats?/2`).
  """
  def noisy_weeks do
    Enum.zip(
      [450, 250, 350, 150, 400, 200, 300, 100, 380, 220, 330, 170, 420, 260, 310, 140],
      [40, -60, 20, -30, 80, -10, 50, -70, -20, 60, -40, 30, -80, 10, -50, 70]
    )
  end

  @doc """
  The weeks before `week`, newest first, one per `{kr, off}`: a dinner at `kr`, paid half as much
  again plus 100 kr, and `off` more. Each was planned and paid before it began, so a backtest sees
  it from the next week on.
  """
  def scaled_weeks(scope, week, weeks) do
    user = user_fixture()

    for {{kr, off}, n} <- Enum.with_index(weeks, 1) do
      week = Date.add(week, -7 * n)
      one_dinner(scope, week, priced_recipe(scope, "Middag #{n}", to_string(kr)))

      {:ok, _} =
        Tore.Costs.log_receipt(scope, %{
          date: week,
          week_start: week,
          store_name: "ICA",
          total_amount: Decimal.new(to_string(kr * 1.5 + 100 + off)),
          user_id: user.id,
          line_items: []
        })

      at = NaiveDateTime.new!(Date.add(week, -2), ~T[12:00:00])

      Repo.update_all(
        from(e in Event, where: e.stream_id == ^Streams.plan(scope, week)),
        [set: [inserted_at: at]],
        Scope.repo_opts(scope)
      )

      Repo.update_all(
        from(r in Receipt, where: r.week_start == ^week),
        [set: [inserted_at: at]],
        Scope.repo_opts(scope)
      )
    end

    :ok
  end
end
