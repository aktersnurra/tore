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

  test "over budget says by how much, open days included" do
    stew = recipe("Gryta", "300")
    {:ok, _} = Planning.assign_recipe(home_scope(), plan(), "mon_dinner", stew.id, 4)
    :ok = Budget.set_week(home_scope(), @week, d("2000"))

    # Monday's stew and six open days at a typical dinner, 300 kr each.
    assert %{over: over} = Budget.status(home_scope(), @week)
    assert Decimal.eq?(over, 100)
  end

  describe "an open day" do
    test "costs what a typical dinner costs; eating out and skipped days don't" do
      for {key, title, kr} <- [
            {"mon_dinner", "Gryta", "100"},
            {"tue_dinner", "Soppa", "40"},
            {"wed_dinner", "Pasta", "60"}
          ] do
        {:ok, _} = Planning.assign_recipe(home_scope(), plan(), key, recipe(title, kr).id, 4)
      end

      {:ok, _} = Planning.eat_out(home_scope(), plan(), "thu_dinner", %{})

      {:ok, _} =
        Planning.assign_recipe(home_scope(), plan(), "fri_dinner", recipe("Tacos", "500").id, 4)

      {:ok, _} = Planning.skip_meal(home_scope(), plan(), "fri_dinner")

      # Saturday and Sunday are open: two dinners at the median of what's cooked, 60 kr. The
      # skipped tacos are neither open nor typical.
      assert %{open_days: 2, open_cost: open_cost, expected: expected} =
               Budget.status(home_scope(), @week)

      assert Decimal.eq?(open_cost, 120)
      assert Decimal.eq?(expected, 320)
    end

    test "a lunch costs what it costs, but isn't a dinner: it neither prices nor opens a day" do
      for {key, title, kr} <- [
            {"mon_dinner", "Gryta", "100"},
            {"tue_dinner", "Soppa", "40"},
            {"wed_dinner", "Pasta", "60"},
            {"sat_lunch", "Pannkakor", "20"}
          ] do
        {:ok, _} = Planning.assign_recipe(home_scope(), plan(), key, recipe(title, kr).id, 4)
      end

      # Thursday to Sunday's dinners are open at the median dinner, 60 kr; the lunch adds its 20.
      assert %{open_days: 4, open_cost: open_cost, expected: expected} =
               Budget.status(home_scope(), @week)

      assert Decimal.eq?(open_cost, 240)
      assert Decimal.eq?(expected, 460)
    end

    test "costs nothing while no dinner has a price" do
      assert %{open_days: 7, open_cost: open_cost, expected: expected} =
               Budget.status(home_scope(), @week)

      assert Decimal.eq?(open_cost, 0)
      assert Decimal.eq?(expected, 0)
    end

    test "counts in past weeks' estimates too, so the calibration doesn't count it twice" do
      stew = recipe("Gryta", "100")
      user = user_fixture()

      # Two weeks before this one: Monday's stew, six open days, and 700 kr paid.
      for weeks_back <- [1, 2] do
        week = Date.add(@week, -7 * weeks_back)
        past = Streams.plan(home_scope(), week)
        {:ok, _} = Planning.assign_recipe(home_scope(), past, "mon_dinner", stew.id, 4)

        {:ok, _} =
          Tore.Costs.log_receipt(home_scope(), %{
            date: week,
            week_start: week,
            store_name: "ICA",
            total_amount: d("700"),
            user_id: user.id
          })
      end

      {:ok, _} = Planning.assign_recipe(home_scope(), plan(), "mon_dinner", stew.id, 4)

      assert %{adjustment: adjustment, expected: expected} = Budget.status(home_scope(), @week)
      assert Decimal.eq?(adjustment, 0)
      assert Decimal.eq?(expected, 700)
    end
  end

  test "the page reads the week, the eight weeks up to it, and where the money went" do
    user = user_fixture()
    :ok = Budget.set_default(home_scope(), d("900"))

    {:ok, _} =
      Planning.assign_recipe(home_scope(), plan(), "mon_dinner", recipe("Gryta", "100").id, 4)

    for {weeks_back, kr} <- [{0, "412"}, {1, "950"}, {3, "850"}] do
      week = Date.add(@week, -7 * weeks_back)

      {:ok, _} =
        Tore.Costs.log_receipt(home_scope(), %{
          date: week,
          week_start: week,
          store_name: "ICA",
          total_amount: d(kr),
          user_id: user.id,
          line_items: [%{product_name: "Lax", total_price: d(kr), category: "fish"}]
        })
    end

    page = Budget.page(home_scope(), @week)

    # Monday's stew and six open days at it: 700 expected, 412 paid, 288 left.
    assert Decimal.eq?(page.status.expected, 700)
    assert Decimal.eq?(page.paid, 412)
    assert Decimal.eq?(page.left, 288)

    assert [first | _] = page.weeks
    assert length(page.weeks) == 8 and first.week_start == Date.add(@week, -49)

    assert [
             {_, nil, false},
             {_, nil, false},
             {_, nil, false},
             {_, nil, false},
             {_, b850, false},
             {_, nil, false},
             {_, b950, true},
             {_, b412, false}
           ] =
             Enum.map(page.weeks, &{&1.week_start, &1.paid, &1.over?})

    assert Decimal.eq?(b850, 850) and Decimal.eq?(b950, 950) and Decimal.eq?(b412, 412)

    # The average is of the weeks before this one that had receipts.
    assert Decimal.eq?(page.average, 900)

    assert [%{section: "fish", total: fish}] = page.sections
    assert Decimal.eq?(fish, 2212)
    assert length(page.receipts) == 3
  end

  test "the page with nothing paid yet" do
    page = Budget.page(home_scope(), @week)
    assert Decimal.eq?(page.paid, 0)
    assert page.average == nil
    assert page.sections == [] and page.receipts == []
  end

  test "the planner hears of the budget only when the week has one" do
    ctx = %{scope: home_scope(), plan_stream_id: plan(), week_start: @week}
    assert BudgetCapsule.to_prompt(BudgetCapsule.build(ctx)) == nil

    :ok = Budget.set_default(home_scope(), d("1800"))
    prompt = BudgetCapsule.to_prompt(BudgetCapsule.build(ctx))
    assert prompt =~ "1800 kr"
    assert prompt =~ "expected to cost about 0 kr"
    refute prompt =~ "open days"

    # Once a dinner has a price, the open days are said to be in the expected cost.
    {:ok, _} =
      Planning.assign_recipe(home_scope(), plan(), "mon_dinner", recipe("Gryta", "100").id, 4)

    prompt = BudgetCapsule.to_prompt(BudgetCapsule.build(ctx))
    assert prompt =~ "expected to cost about 700 kr"
    assert prompt =~ "6 open days at a typical dinner, 600 kr together"
  end
end
