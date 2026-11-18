defmodule ToreWeb.HomeLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, %{"prompt" => "A plate of food."}, %{}}
    end)

    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  defp today_slot_key do
    days = ~w[mon tue wed thu fri sat sun]
    today = Tore.Clock.today()
    dow = Date.day_of_week(today)
    day = Enum.at(days, dow - 1)
    "#{day}_dinner"
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(_fun, 0), do: flunk("Timed out waiting for condition")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  test "opens with today's date", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/today")
    assert html =~ ToreWeb.Dates.long(Tore.Clock.today())
  end

  test "shows nothing planned when no recipe assigned", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/today")
    assert html =~ "Ikväll är öppen"
  end

  test "today does not render the week strip", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/today")
    refute html =~ "Föregående vecka"
  end

  defp plan_id_for_today do
    today = Tore.Clock.today()
    dow = Date.day_of_week(today)
    week_start = Date.add(today, -(dow - 1))
    Tore.Streams.plan(home_scope(), week_start)
  end

  defp seed_tonight_recipe do
    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{
        title: "Chicken gratäng",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: 30
      })

    Tore.Planning.assign_recipe(home_scope(), plan_id_for_today(), today_slot_key(), recipe.id, 4)
    recipe
  end

  describe "tonight's page" do
    test "shows the dish's properties and ingredients, and puts what's missing on the list", %{
      conn: conn
    } do
      Mox.set_mox_global()
      Mox.stub(Tore.MockLLM, :text, fn _s, _u, _o -> {:ok, %{"section" => "other"}, %{}} end)

      {:ok, buns} =
        Tore.Recipes.create(
          home_scope(),
          %{
            title: "Kanelbullar",
            recipe_type: :baking,
            base_servings: 4,
            ingredients: [%{name: "smör", quantity: "100", unit: "g"}, %{name: "kanel"}]
          },
          image: false
        )

      Tore.Planning.assign_recipe(home_scope(), plan_id_for_today(), today_slot_key(), buns.id, 8)
      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "smör"})
      {:ok, view, html} = live(conn, ~p"/today")

      assert html =~ "Bakning"
      assert html =~ "200 g"
      assert view |> element(~s([data-role="at-home"])) |> render() =~ "Saknas: kanel"

      view |> element(~s([data-role="at-home"] button)) |> render_click()
      assert has_element?(view, "#home-added")

      list_id = Tore.Streams.shop_list(home_scope(), Tore.Streams.monday(Tore.Clock.today()))
      {:ok, state} = Tore.Shop.load_list(home_scope(), list_id)
      assert state.items |> Map.values() |> Enum.map(& &1.name) == ["kanel"]
    end
  end

  describe "tonight object sheet" do
    test "long-pressing the tonight card opens a sheet scoped to today with a scoped input",
         %{conn: conn} do
      seed_tonight_recipe()
      {:ok, view, _html} = live(conn, ~p"/today")

      view
      |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
      |> render_hook("open_tonight_sheet", %{})

      html = render(view)
      assert html =~ ~s(phx-submit="tonight_command")

      test_pid = self()

      expect(Tore.MockLLM, :chat_with_tools, fn _sys, msgs, _tools, _opts ->
        [%{role: "user", content: content}] = msgs
        assert content =~ "The user is referring to"
        assert content =~ today_slot_key()
        send(test_pid, :tonight_command_dispatched)

        {:ok, {:message, "done"},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end)

      view
      |> form(~s(form[phx-submit="tonight_command"]), %{command: "make it vegetarian"})
      |> render_submit()

      refute render(view) =~ ~s(phx-submit="tonight_command")

      assert_receive :tonight_command_dispatched, 2_000

      # Wait for the run to finish, or it keeps writing after the test's database is gone.
      eventually(fn -> render(view) =~ "Klar" end)
    end

    test "escape closes the tonight sheet without dispatching", %{conn: conn} do
      seed_tonight_recipe()
      {:ok, view, _html} = live(conn, ~p"/today")

      view
      |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
      |> render_hook("open_tonight_sheet", %{})

      assert render(view) =~ ~s(phx-submit="tonight_command")

      view
      |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
      |> render_hook("close_tonight_sheet", %{})

      refute render(view) =~ ~s(phx-submit="tonight_command")
    end

    test "no sheet opens on the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/today")

      render_hook(view, "open_tonight_sheet", %{})

      refute render(view) =~ ~s(phx-submit="tonight_command")
    end
  end

  test "says the household is eating out tonight instead of nothing planned", %{conn: conn} do
    today = Tore.Clock.today()
    monday = Date.add(today, -(Date.day_of_week(today) - 1))
    day = Enum.at(~w(mon tue wed thu fri sat sun), Date.day_of_week(today) - 1)

    {:ok, _} =
      Tore.Planning.eat_out(
        home_scope(),
        Tore.Streams.plan(home_scope(), monday),
        "#{day}_dinner",
        %{}
      )

    {:ok, _lv, html} = live(conn, ~p"/today")
    assert html =~ "Äter ute ikväll"
    refute html =~ "Ikväll är öppen"
  end

  describe "something else tonight" do
    defp dinner(title, type \\ :meal) do
      {:ok, r} =
        Tore.Recipes.create(home_scope(), %{title: title, recipe_type: type}, image: false)

      r
    end

    setup do
      oxfile = dinner("Oxfilé")
      lax = dinner("Laxpasta")
      _buns = dinner("Kanelbullar", :baking)

      {:ok, _} =
        Tore.Planning.assign_recipe(
          home_scope(),
          plan_id_for_today(),
          today_slot_key(),
          oxfile.id,
          2
        )

      %{oxfile: oxfile, lax: lax}
    end

    test "offers other dinners to choose between, and choosing changes tonight; Undo puts it back",
         %{conn: conn, oxfile: oxfile, lax: lax} do
      {:ok, view, _html} = live(conn, ~p"/today")

      view |> element("button", "Något annat") |> render_click()
      assert eventually(fn -> has_element?(view, ~s([data-choice="#{lax.id}"])) end)
      refute has_element?(view, ~s([data-choice="#{oxfile.id}"]))
      refute render(view) =~ "Kanelbullar"

      html = view |> element(~s([data-choice="#{lax.id}"])) |> render_click()
      assert html =~ "Laxpasta"
      assert html =~ "I stället för Oxfilé."
      {:ok, state} = Tore.Planning.load_plan(home_scope(), plan_id_for_today())
      assert %{recipe_id: id, servings: 2} = state.slots[today_slot_key()]
      assert id == lax.id

      html = view |> element("#tonight-changed button", "Ångra") |> render_click()
      assert html =~ "Oxfilé"
      {:ok, state} = Tore.Planning.load_plan(home_scope(), plan_id_for_today())
      assert state.slots[today_slot_key()].recipe_id == oxfile.id
    end

    test "no dinner tonight is one tap, and can be undone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/today")
      view |> element("button", "Något annat") |> render_click()

      html = view |> element("#choices-sheet button", "Ingen middag ikväll") |> render_click()
      assert html =~ "Ikväll är öppen"

      html = view |> element("button", "Ångra") |> render_click()
      assert html =~ "Oxfilé"

      html = view |> element("#today-menu button", "Ingen middag ikväll") |> render_click()
      assert html =~ "Ikväll är öppen"

      html = view |> element("button", "Ångra") |> render_click()
      assert html =~ "Oxfilé"
    end
  end
end
