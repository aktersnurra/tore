defmodule ToreWeb.HomeLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  import Tore.FakePi

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
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
    test "a planned lunch is one line under the day, opening its recipe", %{conn: conn} do
      seed_tonight_recipe()

      {:ok, soup} =
        Tore.Recipes.create(home_scope(), %{title: "Ärtsoppa", recipe_type: :meal})

      lunch_key = Tore.Streams.slot_key(Tore.Clock.today(), :lunch)
      Tore.Planning.assign_recipe(home_scope(), plan_id_for_today(), lunch_key, soup.id, 4)

      {:ok, view, _html} = live(conn, ~p"/today")

      assert view |> element("[data-role=lunch] a", "Ärtsoppa") |> render() =~
               "/recipes?id=#{soup.id}"

      assert has_element?(view, "h1", "Chicken gratäng")
    end

    test "no lunch line when none is planned", %{conn: conn} do
      seed_tonight_recipe()
      {:ok, view, _html} = live(conn, ~p"/today")
      refute has_element?(view, "[data-role=lunch]")
    end

    test "shows the dish's properties and ingredients, and puts what's missing on the list", %{
      conn: conn
    } do
      Mox.set_mox_global()

      {:ok, buns} =
        Tore.Recipes.create(
          home_scope(),
          %{
            title: "Kanelbullar",
            recipe_type: :baking,
            base_servings: 4,
            ingredients: [%{name: "smör", quantity: "100", unit: "g"}, %{name: "kanel"}]
          }
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

      # Opened again, it says so straight away: there's nothing left to put on the list.
      {:ok, again, _} = live(conn, ~p"/today")
      assert has_element?(again, "#home-added")
      assert has_element?(again, ~s([data-role="to-pantry"][href="/pantry"]))
      refute has_element?(again, ~s([data-role="at-home"] button))

      # Cook now asks about what's missing first, and comes back here from cook mode.
      view |> element(~s(button[data-role="start-cooking"])) |> render_click()
      assert view |> element(~s([data-missing="kanel"])) |> render() =~ "kanel"
      assert has_element?(view, ~s(a[data-role="cook-anyway"][href*="from=%2Ftoday"]))
    end
  end

  describe "after dinner" do
    defp plan_on(date, recipe) do
      plan_id = Tore.Streams.plan(home_scope(), Tore.Streams.monday(date))

      {:ok, _} =
        Tore.Planning.assign_recipe(
          home_scope(),
          plan_id,
          Tore.Streams.slot_key(date),
          recipe.id,
          4
        )
    end

    defp dish(title) do
      {:ok, recipe} =
        Tore.Recipes.create(home_scope(), %{title: title, ingredients: [%{name: "lax"}]})

      recipe
    end

    test "tonight cooked, Today is tomorrow's dinner", %{conn: conn} do
      today = Tore.Clock.today()
      stew = dish("Kycklinggryta")
      salmon = dish("Laxpasta")
      plan_on(today, stew)
      plan_on(Date.add(today, 1), salmon)
      :ok = Tore.Recipes.record_used(home_scope(), stew.id)

      {:ok, view, html} = live(conn, ~p"/today")

      assert html =~ "Laxpasta"

      assert view |> element(~s([data-role="cooked"])) |> render() =~
               "Kycklinggryta, lagad ikväll"

      assert html =~ "Imorgon"
      assert has_element?(view, ~s([data-role="open-recipe"]))
      refute has_element?(view, ~s([data-role="start-cooking"]))
      assert view |> element("#today-menu") |> render() =~ "Ingen middag imorgon"
    end

    test "the home pick's note shows with its way on, unless the page already says it", %{
      conn: conn
    } do
      # A stored pick is read only while the household can use pi.
      fake_pi(%{})
      today = Tore.Clock.today()
      plan_on(today, dish("Kycklinggryta"))
      plan_on(Date.add(today, 1), dish("Laxpasta"))

      {:ok, _} =
        Tore.Harness.Runs.submit(
          home_scope(),
          Tore.Harness.Kinds.HomePick,
          %Tore.Harness.Artifact.HomePick{
            screen: :today,
            source: :model,
            swaps: [],
            note: :buy_for_tomorrow
          },
          %{}
        )

      {:ok, view, _} = live(conn, ~p"/today")
      assert view |> element(~s([data-role="note"])) |> render() =~ "Köp lax före imorgon"

      view |> element(~s([data-role="note"] button)) |> render_click()
      assert view |> element(~s([data-role="note"])) |> render() =~ "På listan"

      tomorrow = Date.add(today, 1)
      list_id = Tore.Streams.shop_list(home_scope(), Tore.Streams.monday(tomorrow))
      {:ok, state} = Tore.Shop.load_list(home_scope(), list_id)
      assert state.items |> Map.values() |> Enum.map(& &1.name) == ["lax"]
    end

    test "at 21:00 Today is tomorrow, cooked or not", %{conn: conn} do
      Application.put_env(:tore, :evening_over, 0)
      on_exit(fn -> Application.put_env(:tore, :evening_over, 24) end)
      plan_on(Tore.Clock.today(), dish("Kycklinggryta"))

      {:ok, view, html} = live(conn, ~p"/today")

      assert html =~ "Imorgon är ledig"
      refute has_element?(view, ~s([data-role="cooked"]))
    end
  end

  describe "tonight object sheet" do
    setup :fake_pi

    test "long-pressing the tonight card opens a sheet whose words go to pi about tonight",
         %{conn: conn, user: user, pi_log: log} do
      System.put_env("FAKE_PI_REPLY", "Klart.")
      seed_tonight_recipe()
      {:ok, view, _html} = live(conn, ~p"/today")

      view
      |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
      |> render_hook("open_tonight_sheet", %{})

      html = render(view)
      assert html =~ ~s(phx-submit="tonight_command")

      view
      |> form(~s(form[phx-submit="tonight_command"]), %{command: "make it vegetarian"})
      |> render_submit()

      refute render(view) =~ ~s(phx-submit="tonight_command")
      assert eventually(fn -> has_element?(view, ~s([data-role="pi-reply"]), "Klart.") end)

      # Opening Today may also start a home_pick job in the same fake.
      records = pi_records(log)

      assert Enum.any?(
               records,
               &(&1["session"] == Tore.Chats.session(Tore.Chats.current(scope_fixture(user))))
             )

      %{"message" => message} =
        Enum.find(records, &(&1["type"] == "prompt" and &1["message"] =~ "From the Today screen"))

      assert message =~ "From the Today screen, about tonight's dinner"
      assert message =~ Date.to_iso8601(Tore.Clock.today())
      assert message =~ "make it vegetarian"

      # The chat used elsewhere afterwards doesn't write into the note.
      assert eventually(fn -> not has_element?(view, ~s([data-role="pi-working"])) end)
      session = Tore.Chats.session(Tore.Chats.current(scope_fixture(user)))

      send(
        view.pid,
        {:pi, session, %{"type" => "message_start", "message" => %{"role" => "assistant"}}}
      )

      send(
        view.pid,
        {:pi, session,
         %{
           "type" => "message_update",
           "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Ett annat svar"}
         }}
      )

      assert has_element?(view, ~s([data-role="pi-reply"]), "Klart.")
      refute render(view) =~ "Ett annat svar"
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
        Tore.Recipes.create(home_scope(), %{title: title, recipe_type: type})

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
