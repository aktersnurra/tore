defmodule ToreWeb.BudgetLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Tore.{Budget, Planning, Recipes, Streams}

  setup do
    user = user_fixture(name: "Tester")
    %{conn: Plug.Test.init_test_session(build_conn(), %{user_id: user.id})}
  end

  defp week_start, do: Streams.monday(Tore.Clock.today())

  # A recipe for 4 whose one ingredient is estimated at `kr` per item.
  defp recipe(title, kr) do
    {:ok, recipe} =
      Recipes.create(
        home_scope(),
        %{title: title, base_servings: 4, ingredients: [%{name: title <> " i", quantity: 1}]},
        image: false
      )

    Tore.Repo.update_all(
      from(i in Tore.Recipes.Ingredient, where: i.name == ^(title <> " i")),
      [set: [estimated_price: Decimal.new(kr), estimated_unit: "st"]],
      Tore.Scope.repo_opts(home_scope())
    )

    recipe
  end

  defp plan(slot, recipe) do
    {:ok, _} =
      Planning.assign_recipe(
        home_scope(),
        Streams.plan(home_scope(), week_start()),
        slot,
        recipe.id,
        4
      )
  end

  describe "the plan screen" do
    test "shows the week's estimate against its budget, and how far over", %{conn: conn} do
      plan("mon_dinner", recipe("Gryta", "300"))
      :ok = Budget.set_default(home_scope(), Decimal.new(2000))

      {:ok, view, html} = live(conn, ~p"/plan")
      assert html =~ "Runt 300 av 2 000 kr, 0 av 1 ingredienser har pris"

      :ok = Budget.set_week(home_scope(), week_start(), Decimal.new(250))
      plan("tue_dinner", recipe("Soppa", "50"))
      send(view.pid, {:events, []})

      assert view |> element(~s([data-role="week-estimate"])) |> render() =~
               "Runt 350 av 250 kr, 100 kr över"
    end

    test "with no plan and no budget there's no estimate line", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/plan")
      refute has_element?(view, ~s([data-role="week-estimate"]))
    end

    test "a day's alternatives show what they'd change", %{conn: conn} do
      plan("mon_dinner", recipe("Gryta", "120"))
      cheaper = recipe("Soppa", "85")

      {:ok, view, _html} = live(conn, ~p"/plan")
      render_click(view, "open_slot", %{"slot_key" => "mon_dinner"})
      :timer.sleep(150)

      assert view
             |> element(~s(button[phx-value-id="#{cheaper.id}"] [data-role="price-diff"]))
             |> render() =~ "−35 kr"
    end
  end

  describe "settings" do
    test "sets the usual weekly budget, and blank removes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> form("#budget form", %{amount: "2 000"}) |> render_submit()
      assert html =~ "Sparat."
      assert Budget.amount(home_scope(), week_start()) == Decimal.new(2000)

      html = view |> form("#budget form", %{amount: "tvåtusen"}) |> render_submit()
      assert html =~ "Skriv ett belopp i kronor."
      assert Budget.amount(home_scope(), week_start()) == Decimal.new(2000)

      view |> form("#budget form", %{amount: ""}) |> render_submit()
      assert Budget.amount(home_scope(), week_start()) == nil
    end
  end
end
