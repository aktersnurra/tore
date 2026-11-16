defmodule Tore.BudgetTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.{Budget, Planning, Recipes, Streams}
  alias Tore.Harness.Capsules.BudgetCapsule
  alias Tore.Recipes.Ingredient

  @week ~D[2026-11-16]

  defp d(s), do: Decimal.new(s)

  # A recipe for 4 whose one ingredient is estimated at `kr` per item, used once per serving set.
  defp recipe(title, kr) do
    {:ok, recipe} =
      Recipes.create(
        home_scope(),
        %{
          title: title,
          recipe_type: :meal,
          base_servings: 4,
          ingredients: [%{name: title <> " i", quantity: 1, unit: "st"}]
        },
        image: false
      )

    Repo.update_all(
      from(i in Ingredient, where: i.name == ^(title <> " i")),
      [set: [estimated_price: d(kr), estimated_unit: "st"]],
      Tore.Scope.repo_opts(home_scope())
    )

    recipe
  end

  defp plan, do: Streams.plan(home_scope(), @week)

  test "a week's own budget, else the default, else none" do
    assert Budget.amount(home_scope(), @week) == nil

    :ok = Budget.set_default(home_scope(), d("2000"))
    assert Budget.amount(home_scope(), @week) == d("2000")

    :ok = Budget.set_week(home_scope(), Date.add(@week, 2), d("1500"))
    assert Budget.amount(home_scope(), @week) == d("1500")
    assert Budget.amount(home_scope(), Date.add(@week, 7)) == d("2000")

    :ok = Budget.set_week(home_scope(), @week, nil)
    assert Budget.amount(home_scope(), @week) == d("2000")

    assert {:error, :invalid_amount} = Budget.set_week(home_scope(), @week, d("0"))
  end

  test "the estimate counts cooked dinners at their servings, not leftovers or skipped days" do
    stew = recipe("Gryta", "100")
    soup = recipe("Soppa", "40")

    {:ok, _} = Planning.assign_recipe(home_scope(), plan(), "mon_dinner", stew.id, 8)

    {:ok, _} =
      Planning.assign_with_leftovers(home_scope(), plan(), "tue_dinner", soup.id, 4, [
        "wed_dinner"
      ])

    {:ok, _} = Planning.assign_recipe(home_scope(), plan(), "thu_dinner", soup.id, 4)
    {:ok, _} = Planning.skip_meal(home_scope(), plan(), "thu_dinner")

    # Stew for 8 is twice the recipe; the soup once; Wednesday's leftovers and Thursday's skip
    # cost nothing.
    assert %{budget: nil, over: nil, estimate: %{amount: amount, priced: 0, total: 2}} =
             Budget.status(home_scope(), @week)

    assert amount == d("240.00")
  end

  test "over budget says by how much" do
    stew = recipe("Gryta", "300")
    {:ok, _} = Planning.assign_recipe(home_scope(), plan(), "mon_dinner", stew.id, 4)
    :ok = Budget.set_week(home_scope(), @week, d("250"))

    assert %{over: over} = Budget.status(home_scope(), @week)
    assert Decimal.eq?(over, 50)
  end

  test "the planner hears of the budget only when the week has one" do
    ctx = %{scope: home_scope(), plan_stream_id: plan(), week_start: @week}
    assert BudgetCapsule.to_prompt(BudgetCapsule.build(ctx)) == nil

    :ok = Budget.set_default(home_scope(), d("1800"))
    prompt = BudgetCapsule.to_prompt(BudgetCapsule.build(ctx))
    assert prompt =~ "1800 kr"
    assert prompt =~ "estimated at 0 kr"
  end
end
