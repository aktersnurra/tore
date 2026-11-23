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

    test "what's missing is a list to buy; Cook now asks about it first", %{
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
      {:ok, view, _html} = live(conn, ~p"/today")

      # What to buy, as Shop lists it: a head with how many, then a row each with its picture.
      # The ingredients themselves are on the recipe page.
      assert view |> element(~s([data-role="to-buy"] h2)) |> render() =~ "Handla"

      # The things to do sit together, in one row: cook, something else, ask.
      for role <- ["start-cooking", "something-else", "ask-tore"],
          do: assert(has_element?(view, ~s([data-role="actions"] [data-role="#{role}"])))

      assert has_element?(
               view,
               ~s([data-role="to-buy"] li[data-buy="kanel"] img[src^="/images/food/"])
             )

      refute has_element?(view, ~s([data-role="to-buy"] li[data-buy="smör"]))
      refute has_element?(view, ~s([data-role="ingredients"]))

      # The photo opens the recipe; there's no menu.
      assert has_element?(view, ~s(a[data-role="cover"][href="/recipes?id=#{buns.id}"]))
      refute has_element?(view, "#today-menu")

      # Fråga Tore asks about what's missing, in the dish's conversation: one way to ask.
      ask = view |> element(~s(a[data-role="ask-tore"])) |> render()
      assert ask =~ "recipe=#{buns.id}" and ask =~ "kanel"

      # Cook now is where it always is; with something missing it first asks what to use
      # instead, and can still cook anyway, back here after.
      refute has_element?(view, ~s([data-role="swap-missing"]))
      view |> element(~s(button[data-role="start-cooking"])) |> render_click()

      assert view |> element(~s([data-missing="kanel"])) |> render() =~ "kanel"
      assert has_element?(view, ~s(a[data-role="cook-anyway"][href*="from=%2Ftoday"]))
    end
  end

  describe "ticking off what's missing" do
    defp tonight_needs(names) do
      {:ok, dish} =
        Tore.Recipes.create(home_scope(), %{
          title: "Pannkakor",
          recipe_type: :meal,
          ingredients: Enum.map(names, &%{name: &1})
        })

      Tore.Planning.assign_recipe(home_scope(), plan_id_for_today(), today_slot_key(), dish.id, 4)
      dish
    end

    defp missing, do: Tore.Pantry.at_home(home_scope(), ["mjöl", "ägg"]).missing

    test "a tick says it's bought: at home now, the row stays ticked, tapping again undoes it",
         %{conn: conn} do
      tonight_needs(["mjöl", "ägg"])
      {:ok, view, _html} = live(conn, ~p"/today")
      box = ~s([data-buy="ägg"] button[role="checkbox"])

      view |> element(box) |> render_click()
      assert missing() == ["mjöl"]
      assert view |> element(box) |> render() =~ ~s(aria-checked="true")
      assert has_element?(view, ~s(li.is-checked[data-buy="ägg"]))

      view |> element(box) |> render_click()
      assert missing() == ["mjöl", "ägg"]
      assert view |> element(box) |> render() =~ ~s(aria-checked="false")

      # Eggs were never kept, so taking the tick back leaves no row behind for Hemma to show.
      refute Tore.Pantry.get_by_name(home_scope(), "ägg")

      # With all of it ticked, Cook now goes straight to cooking.
      view |> element(box) |> render_click()
      view |> element(~s([data-buy="mjöl"] button[role="checkbox"])) |> render_click()
      assert view |> element(~s(a[data-role="start-cooking"])) |> render() =~ "/cook"
    end

    test "taking back a tick on something used up leaves it used up", %{conn: conn} do
      tonight_needs(["mjöl", "ägg"])
      {:ok, flour} = Tore.Pantry.add_item(home_scope(), %{name: "mjöl"})
      {:ok, _} = Tore.Pantry.mark_gone(home_scope(), flour.id)

      {:ok, view, _html} = live(conn, ~p"/today")
      box = ~s([data-buy="mjöl"] button[role="checkbox"])
      view |> element(box) |> render_click()
      view |> element(box) |> render_click()

      assert missing() == ["mjöl", "ägg"]
      assert Tore.Repo.reload!(flour, Tore.Scope.repo_opts(home_scope())).belief == "missing"
    end

    test "what's on this week's list is ticked there too", %{conn: conn} do
      tonight_needs(["mjöl", "ägg"])
      list_id = Tore.Streams.shop_list(home_scope(), Tore.Streams.monday(Tore.Clock.today()))
      {:ok, _} = Tore.Shop.add_item(home_scope(), list_id, "Ägg", nil, nil, nil)

      {:ok, view, _html} = live(conn, ~p"/today")
      view |> element(~s([data-buy="ägg"] button[role="checkbox"])) |> render_click()

      {:ok, %{items: items}} = Tore.Shop.load_list(home_scope(), list_id)
      assert [%{name: "Ägg", checked: true}] = Map.values(items)
      assert missing() == ["mjöl"]

      view |> element(~s([data-buy="ägg"] button[role="checkbox"])) |> render_click()
      {:ok, %{items: items}} = Tore.Shop.load_list(home_scope(), list_id)
      assert [%{checked: false}] = Map.values(items)
      assert missing() == ["mjöl", "ägg"]
    end
  end

  describe "can I start?" do
    defp tonight_with(names) do
      {:ok, dish} =
        Tore.Recipes.create(home_scope(), %{
          title: "Pannkakor",
          recipe_type: :meal,
          base_servings: 4,
          ingredients: Enum.map(names, &%{name: &1})
        })

      Tore.Planning.assign_recipe(home_scope(), plan_id_for_today(), today_slot_key(), dish.id, 4)
      dish
    end

    # Milk, a weekly basic, last seen ten days ago: likely drunk, so Tore is unsure.
    defp unsure_milk do
      :ok = Tore.Basics.ask(home_scope(), [%{name: "Mjölk"}])
      {:ok, milk, _, _} = Tore.Pantry.upsert_belief(home_scope(), %{catalogue_name: "Mjölk"})
      seen = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)
      {:ok, milk} = milk |> Ecto.Changeset.change(last_seen_at: seen) |> Tore.Repo.update()
      milk
    end

    test "with everything at home it says so, and nothing else about the dish", %{conn: conn} do
      tonight_with(["Ägg"])
      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "ägg"})

      {:ok, view, _html} = live(conn, ~p"/today")

      # Tonight, Cook now is the answer: nothing to say about what's at home.
      assert view |> element(~s(a[data-role="start-cooking"])) |> render() =~ "/cook"
      refute has_element?(view, ~s([data-role="ready"]))
      refute has_element?(view, ~s([data-role="unsure"]))
      refute has_element?(view, "dl.props")
    end

    test "when it'll be ready shows only when cooking could start now", %{conn: conn} do
      {:ok, dish} =
        Tore.Recipes.create(home_scope(), %{
          title: "Omelett",
          recipe_type: :meal,
          cook_time_minutes: 20
        })

      Tore.Planning.assign_recipe(home_scope(), plan_id_for_today(), today_slot_key(), dish.id, 2)
      {:ok, view, _html} = live(conn, ~p"/today")

      # The facts, as the recipe page gives its times: how long, when it's ready, for how many.
      assert view |> element(~s([data-role="when"])) |> render() =~ "Totalt:"
      assert has_element?(view, ~s([data-role="when"] [data-role="ready-by"]), "Klar:")
      assert view |> element(~s([data-role="when"])) |> render() =~ "Portioner"

      # The day is a tag on the photo, with the dish's name.
      assert has_element?(view, ~s([data-role="cover"] .tag-red), "Ikväll")

      # After midnight, "ready 00:57" says nothing.
      Application.put_env(:tore, :cooking_from_hour, 24)
      on_exit(fn -> Application.put_env(:tore, :cooking_from_hour, 0) end)
      {:ok, view, _html} = live(conn, ~p"/today")
      refute has_element?(view, ~s([data-role="ready-by"]))
    end

    test "what Tore is unsure of is asked: Finns makes it sure, Slut puts it with what's missing",
         %{conn: conn} do
      tonight_with(["Mjölk", "Ägg"])
      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "ägg"})
      milk = unsure_milk()
      row = ~s([data-role="unsure"] [data-item="#{milk.id}"])

      {:ok, view, _html} = live(conn, ~p"/today")
      refute has_element?(view, ~s([data-role="ready"]))
      assert view |> element(row) |> render() =~ "Mjölk"

      view |> element(row <> ~s( [data-role="gone"])) |> render_click()
      refute has_element?(view, row)
      assert has_element?(view, ~s([data-role="to-buy"] li[data-buy="Mjölk"]))

      unsure_milk()
      {:ok, view, _html} = live(conn, ~p"/today")
      view |> element(row <> ~s( [data-role="still-there"])) |> render_click()
      refute has_element?(view, ~s([data-role="unsure"]))
      assert has_element?(view, ~s(a[data-role="start-cooking"]))
    end

    test "it asks about three at most, and says how many more there are", %{conn: conn} do
      names = ["Mjölk", "Fil", "Bröd", "Ost", "Juice"]
      tonight_with(names)
      :ok = Tore.Basics.ask(home_scope(), Enum.map(names, &%{name: &1}))
      seen = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)

      for name <- names do
        {:ok, item, _, _} = Tore.Pantry.upsert_belief(home_scope(), %{catalogue_name: name})
        {:ok, _} = item |> Ecto.Changeset.change(last_seen_at: seen) |> Tore.Repo.update()
      end

      {:ok, view, _html} = live(conn, ~p"/today")

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find(~s([data-role="unsure"] [data-item]))
             |> length() == 3

      assert view |> element(~s([data-role="unsure"] li a[href="/pantry"])) |> render() =~
               "2 till"
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

    test "Ask Tore opens the conversation about the dish, as on its recipe page", %{conn: conn} do
      stew = dish("Kycklinggryta")
      plan_on(Tore.Clock.today(), stew)

      {:ok, view, _html} = live(conn, ~p"/today")

      ask = view |> element(~s(a[data-role="ask-tore"])) |> render()
      assert ask =~ "recipe=#{stew.id}" and ask =~ "return_to=%2Ftoday"
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
      assert has_element?(view, ~s(a[data-role="cover"][href="/recipes?id=#{salmon.id}"]))
      refute has_element?(view, ~s([data-role="start-cooking"]))
      view |> element("button", "Något annat") |> render_click()
      assert has_element?(view, "#choices-sheet button", "Ingen middag imorgon")
      eventually(fn -> !has_element?(view, ~s(#choices-sheet [role="status"])) end)
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
               &(&1["session"] == Tore.Pi.screen_session(scope_fixture(user)))
             )

      %{"message" => message} =
        Enum.find(records, &(&1["type"] == "prompt" and &1["message"] =~ "From the Today screen"))

      assert message =~ "From the Today screen, about tonight's dinner"
      assert message =~ Date.to_iso8601(Tore.Clock.today())
      assert message =~ "make it vegetarian"

      # The chat used elsewhere afterwards doesn't write into the note.
      assert eventually(fn -> not has_element?(view, ~s([data-role="pi-working"])) end)
      session = Tore.Pi.screen_session(scope_fixture(user))

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
    end
  end

  describe "the chef" do
    defp cook(times) do
      {:ok, recipe} = Tore.Recipes.create(home_scope(), %{title: "Pasta", recipe_type: :meal})
      for _ <- 1..times, do: {:ok, _} = Tore.Chef.cooked(home_scope(), recipe.id, [])
    end

    test "starts at the sink, with no dinners yet", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/today")

      assert view |> element("#chef-row") |> render() =~ "Diskplockare"
      assert has_element?(view, ~s(#chef-row [data-chef][data-stage="dishwasher"]))
    end

    test "grows with dinners cooked, and its sheet says how far and what's next", %{conn: conn} do
      cook(8)
      {:ok, view, _} = live(conn, ~p"/today")
      assert view |> element("#chef-row") |> render() =~ "Lärling"

      view |> element("#chef-row button[data-role=open-chef]") |> render_click()
      sheet = view |> element("#chef-sheet") |> render()
      assert sheet =~ "8 middagar lagade hemma"
      assert sheet =~ "17 kvar till Kock"

      render_click(view, "close_chef", %{})
      refute has_element?(view, "#chef-sheet")
    end
  end
end
