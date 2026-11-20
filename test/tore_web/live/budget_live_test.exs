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
        %{title: title, base_servings: 4, ingredients: [%{name: title <> " i", quantity: 1}]}
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

  defp eat_out(week, days) do
    for day <- days do
      {:ok, _} =
        Planning.eat_out(home_scope(), Streams.plan(home_scope(), week), day <> "_dinner", %{})
    end
  end

  defp receipt(week, kr, lines \\ []) do
    {:ok, receipt} =
      Tore.Costs.log_receipt(home_scope(), %{
        date: week,
        week_start: week,
        store_name: "ICA Supermarket",
        total_amount: Decimal.new(kr),
        user_id: user_fixture().id,
        line_items:
          for {name, price, section} <- lines do
            %{product_name: name, total_price: Decimal.new(price), category: section}
          end
      })

    receipt
  end

  describe "the budget page" do
    setup do
      eat_out(week_start(), ~w[tue wed thu fri sat sun])
      plan("mon_dinner", recipe("Gryta", "700"))
      :ok = Budget.set_from(home_scope(), week_start(), Decimal.new(900))
      :ok
    end

    test "answers where the week lands, with what's paid and what's left", %{conn: conn} do
      receipt(week_start(), "412", [
        {"Laxfilé", "160", "fish"},
        {"Kycklinglårfilé", "252", "meat"}
      ])

      receipt(Date.add(week_start(), -7), "950")

      {:ok, view, html} = live(conn, ~p"/budget")

      assert html =~ "Veckobudget"
      assert html =~ "Vecka #{Streams.week_number(week_start())}"
      assert view |> element(~s([data-role="lands"])) |> render() =~ "Veckan landar runt 700 kr"
      assert view |> element(~s([data-role="budget-tag"])) |> render() =~ "200 kr under budget"
      assert view |> element(~s([data-role="kpi-paid"])) |> render() =~ "412 kr"
      assert view |> element(~s([data-role="kpi-left"])) |> render() =~ "288 kr"
      assert view |> element(~s([data-role="kpi-average"])) |> render() =~ "950 kr"

      # Eight weeks, last week over its budget in red, this week's paid with what's expected.
      assert length(Regex.scan(~r/data-role="chart-week"/, html)) == 8
      assert view |> element(~s([data-role="chart"] .lab.over)) |> render() =~ "950"
      assert view |> element(~s([data-role="chart"] .lab.now)) |> render() =~ "≈700"

      # Where the money went, biggest first, opening to what was bought.
      names =
        ~r/data-role="section-name"[^>]*>\s*([^<]+?)\s*</
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      assert names == ["Kött", "Fisk &amp; skaldjur"]
      assert view |> element(~s([data-role="section-item"]), "Laxfilé") |> render() =~ "1 gång"

      assert view |> element(~s([data-role="receipt"]), "412 kr") |> render() =~ "ICA Supermarket"
    end

    test "the chart draws each week's budget, and says where it changed", %{conn: conn} do
      :ok = Budget.set_from(home_scope(), Date.add(week_start(), -21), Decimal.new(1200))
      {:ok, view, _html} = live(conn, ~p"/budget")

      labels =
        for el <-
              view
              |> element(~s([data-role="chart"]))
              |> render()
              |> LazyHTML.from_fragment()
              |> LazyHTML.query(".bud-l"),
            do: el |> LazyHTML.text() |> String.trim()

      assert labels == ["Budget 1 200", "900"]
    end

    test "a budget changed on the page holds from the week shown on", %{conn: conn} do
      :ok = Budget.set_from(home_scope(), Date.add(week_start(), -28), Decimal.new(900))
      {:ok, view, _html} = live(conn, ~p"/budget")
      view |> element(~s([data-role="kpi-budget"] button)) |> render_click()
      view |> form(~s([data-role="budget-form"]), %{"amount" => "1 100"}) |> render_submit()

      assert Decimal.eq?(Budget.amount(home_scope(), week_start()), 1100)
      assert Decimal.eq?(Budget.amount(home_scope(), Date.add(week_start(), 14)), 1100)
      assert Decimal.eq?(Budget.amount(home_scope(), Date.add(week_start(), -7)), 900)
    end

    test "the budget is changed where it's shown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/budget")

      view |> element(~s([data-role="kpi-budget"] button)) |> render_click()

      assert view
             |> form(~s([data-role="budget-form"]), %{"amount" => "tusen"})
             |> render_submit() =~
               "Skriv ett belopp i kronor."

      # The field keeps what was typed, so the error sits next to its cause.
      assert view |> element(~s(#budget-input)) |> render() =~ ~s(value="tusen")
      assert Decimal.eq?(Budget.amount(home_scope(), week_start()), 900)

      view |> form(~s([data-role="budget-form"]), %{"amount" => "1 000"}) |> render_submit()
      assert Decimal.eq?(Budget.amount(home_scope(), week_start()), 1000)
      assert view |> element(~s([data-role="budget-tag"])) |> render() =~ "300 kr under budget"
      refute has_element?(view, ~s([data-role="budget-form"]))

      # Blank means no budget, and the tag goes with it.
      view |> element(~s([data-role="kpi-budget"] button)) |> render_click()
      view |> form(~s([data-role="budget-form"]), %{"amount" => ""}) |> render_submit()
      assert Budget.amount(home_scope(), week_start()) == nil
      refute has_element?(view, ~s([data-role="budget-tag"]))
    end

    test "with nothing paid, says so instead of an empty list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/budget")
      assert html =~ "Inga kvittorader att dela upp de här veckorna än."
      refute html =~ ~s(data-role="receipt")
    end

    test "a receipt opens with its lines by section, and a line can be moved", %{conn: conn} do
      receipt =
        receipt(week_start(), "412", [
          {"Kycklinglårfilé", "109", "meat"},
          {"Laxfilé", "79.9", "meat"},
          {"Mjölk", "18.9", "dairy"}
        ])

      {:ok, view, _html} = live(conn, ~p"/budget")
      view |> element(~s([data-role="receipt"]), "412 kr") |> render_click()
      assert_patch(view, ~p"/budget/receipts/#{receipt.id}")

      sheet = view |> element(~s([data-role="receipt-sheet"])) |> render()
      assert sheet =~ "ICA Supermarket" and sheet =~ "412 kr"
      assert view |> element(~s([data-role="receipt-group"]), "Kött") |> render() =~ "188,90"

      # Laxfilé was fish all along.
      view |> element(~s([data-role="receipt-line"]), "Laxfilé") |> render_click()

      view
      |> element(~s([data-role="move-to"][phx-value-section="fish"]))
      |> render_click()

      assert view |> element(~s([data-role="receipt-group"]), "Fisk") |> render() =~ "Laxfilé"
      assert view |> element(~s([data-role="receipt-group"]), "Kött") |> render() =~ "109,00"

      # The week it counts towards moves to the next, and back.
      view |> element(~s([data-role="receipt-week"])) |> render_click()

      assert Tore.Costs.get_receipt(home_scope(), receipt.id).week_start ==
               Date.add(week_start(), 7)

      view |> element(~s([data-role="close-receipt"])) |> render_click()
      assert_patch(view, ~p"/budget")
      refute has_element?(view, ~s([data-role="receipt-sheet"]))
    end

    test "another household's receipt doesn't open", %{conn: conn} do
      other = scope_fixture(household_fixture())

      {:ok, theirs} =
        Tore.Costs.log_receipt(other, %{
          date: week_start(),
          store_name: "Willys",
          total_amount: Decimal.new(10),
          user_id: user_fixture().id
        })

      assert {:error, {:live_redirect, %{to: "/budget"}}} =
               live(conn, ~p"/budget/receipts/#{theirs.id}")
    end

    test "is in the menu and on Plan's budget line, and no longer in Settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/plan")
      assert has_element?(view, ~s(a[href="/budget"] [data-role="week-estimate"]))

      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ ~s(id="budget")
    end
  end

  describe "the plan screen" do
    test "shows the week's estimate against its budget, and how far over", %{conn: conn} do
      eat_out(week_start(), ~w[wed thu fri sat sun])
      plan("mon_dinner", recipe("Gryta", "300"))
      :ok = Budget.set_from(home_scope(), week_start(), Decimal.new(2000))

      # Tuesday is open, so it counts as a typical dinner: 300 kr.
      {:ok, view, html} = live(conn, ~p"/plan")
      assert html =~ "runt 600 av 2 000 kr"

      :ok = Budget.set_week(home_scope(), week_start(), Decimal.new(250))
      plan("tue_dinner", recipe("Soppa", "50"))
      send(view.pid, {:events, []})

      assert view |> element(~s([data-role="week-estimate"])) |> render() =~
               "runt 350 av 250 kr, 100 kr över"
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

  describe "after the week" do
    test "the plan screen gives the verdict for a week that has ended", %{conn: conn} do
      last_week = Date.add(week_start(), -7)

      {:ok, recipe} =
        Recipes.create(
          home_scope(),
          %{title: "Gryta", base_servings: 4, ingredients: [%{name: "bönor", quantity: 1}]}
        )

      Tore.Repo.update_all(
        from(i in Tore.Recipes.Ingredient, where: i.name == "bönor"),
        [set: [estimated_price: Decimal.new(1000), estimated_unit: "st"]],
        Tore.Scope.repo_opts(home_scope())
      )

      {:ok, _} =
        Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), last_week),
          "mon_dinner",
          recipe.id,
          4
        )

      eat_out(last_week, ~w[tue wed thu fri sat sun])
      :ok = Budget.set_week(home_scope(), last_week, Decimal.new(1200))

      {:ok, _} =
        Tore.Costs.log_receipt(home_scope(), %{
          date: Date.add(last_week, 2),
          store_name: "ICA",
          total_amount: Decimal.new(1100),
          user_id: user_fixture().id
        })

      {:ok, view, _html} = live(conn, ~p"/plan")
      render_click(view, "prev_week", %{})

      assert view |> element(~s([data-role="week-verdict"])) |> render() =~
               "Handlat för 1 100 av 1 200 kr, runt 10 % över uppskattningen"
    end

    test "a receipt on Shop shows its week, and a tap moves it", %{conn: conn} do
      date = Tore.Clock.today()

      {:ok, receipt} =
        Tore.Costs.log_receipt(home_scope(), %{
          date: date,
          store_name: "ICA",
          total_amount: Decimal.new(300),
          user_id: user_fixture().id
        })

      week = Tore.Streams.week_number(date)
      {:ok, view, _html} = live(conn, ~p"/shop")

      assert view |> element(~s([data-role="receipt-week"])) |> render() =~ "Vecka #{week}"

      view |> element(~s([data-role="receipt-week"])) |> render_click()

      assert Tore.Repo.get!(Tore.Costs.Receipt, receipt.id, Tore.Scope.repo_opts(home_scope())).week_start ==
               Date.add(week_start(), 7)
    end
  end

  describe "the forecast" do
    setup do
      Tore.BudgetFixtures.one_dinner(
        home_scope(),
        week_start(),
        Tore.BudgetFixtures.priced_recipe(home_scope(), "Fest", "300")
      )
    end

    test "until a rung with a range has earned it, the week lands around a number", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/budget")
      render_async(view, 5_000)

      assert view |> element(~s([data-role="lands"])) |> render() =~ "Veckan landar runt"
    end

    test "once a rung with a range has earned it, the week lands in that range", %{conn: conn} do
      Tore.BudgetFixtures.scaled_weeks(
        home_scope(),
        week_start(),
        Tore.BudgetFixtures.noisy_weeks()
      )

      {:ok, view, _html} = live(conn, ~p"/budget")
      render_async(view, 5_000)

      %{low: low, high: high} =
        Tore.Budget.Forecast.predict(
          home_scope(),
          week_start(),
          NaiveDateTime.utc_now(),
          Tore.Budget.Forecast.live(home_scope())
        )

      floor = low |> Decimal.div(10) |> Decimal.round(0, :floor) |> Decimal.mult(10)
      ceiling = high |> Decimal.div(10) |> Decimal.round(0, :ceiling) |> Decimal.mult(10)

      assert view |> element(~s([data-role="lands"])) |> render() =~
               "Veckan landar på #{Tore.Money.format(floor)}–#{Tore.Money.format(ceiling)} kr"
    end
  end
end
