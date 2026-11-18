defmodule ToreWeb.PlannerLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  import Tore.FakePi

  alias Tore.{Recipes, Planning}

  setup :verify_on_exit!

  setup do
    user = user_fixture(name: "Gustaf")

    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: "Roast chicken",
        recipe_type: :meal,
        base_servings: 6,
        prep_time_minutes: 10,
        cook_time_minutes: 60
      })

    %{user: user, recipe: recipe}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp this_plan_id do
    today = Tore.Clock.today()
    dow = Date.day_of_week(today)
    week_start = Date.add(today, -(dow - 1))
    Tore.Streams.plan(home_scope(), week_start)
  end

  describe "the week's list" do
    test "tonight's dish is tagged, and the open days ahead are New dinner rows", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      today = Tore.Clock.today()
      key = Tore.Streams.slot_key(today)
      {:ok, _} = Planning.assign_recipe(home_scope(), this_plan_id(), key, recipe.id, 4)

      {:ok, lv, _html} = conn |> authed(user) |> live(~p"/plan")

      tonight = lv |> element("#slot-#{key}") |> render()
      assert tonight =~ "Roast chicken"
      assert tonight =~ "Ikväll"

      open_ahead = 7 - Date.day_of_week(today)
      rows = Regex.scan(~r/data-role="new-dinner"/, render(lv))
      assert length(rows) == open_ahead

      # The row says what the day is, not how many it serves.
      refute tonight =~ "4 portioner"
    end

    test "a dinner cooked on its day is tagged Cooked instead of Tonight", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      today = Tore.Clock.today()
      key = Tore.Streams.slot_key(today)
      {:ok, _} = Planning.assign_recipe(home_scope(), this_plan_id(), key, recipe.id, 4)
      :ok = Recipes.record_used(home_scope(), recipe.id)

      {:ok, lv, _html} = conn |> authed(user) |> live(~p"/plan")

      tonight = lv |> element("#slot-#{key}") |> render()
      assert tonight =~ "Lagad"
      refute tonight =~ "Ikväll"
    end
  end

  describe "the month" do
    test "shows each day's dinner, steps by month, and a day opens its week", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      today = Tore.Clock.today()
      key = Tore.Streams.slot_key(today)
      {:ok, _} = Planning.assign_recipe(home_scope(), this_plan_id(), key, recipe.id, 4)

      {:ok, lv, _html} = conn |> authed(user) |> live(~p"/plan")
      html = lv |> element(~s([data-plan-view="month"])) |> render_click()

      assert has_element?(lv, "#plan-month")
      assert html =~ "1 middag planerad"
      # The heading is the month, capitalised: "November 2026".
      assert html =~ ~r/[A-ZÅÄÖ][a-zåäö]+ #{today.year}/u
      assert has_element?(lv, ~s(#plan-month [data-date="#{today}"]), "Roast chicken")
      refute has_element?(lv, "#slot-#{key}")

      lv |> element(~s(button[aria-label="Nästa månad"])) |> render_click()
      refute has_element?(lv, ~s(#plan-month [data-date="#{today}"]))
      lv |> element(~s(button[aria-label="Föregående månad"])) |> render_click()

      lv |> element(~s(#plan-month [data-date="#{today}"])) |> render_click()
      refute has_element?(lv, "#plan-month")
      assert lv |> element("#slot-#{key}") |> render() =~ "Roast chicken"
    end
  end

  describe "an earlier run" do
    test "a question left waiting from before isn't shown when Plan opens", %{
      conn: conn,
      user: user
    } do
      Tore.RunFixtures.pending_question_fixture(home_scope())

      {:ok, lv, _html} = conn |> authed(user) |> live(~p"/plan")

      refute render(lv) =~ "Which Monday?"
    end
  end

  describe "slot modal" do
    test "open_slot loads suggestions and shows modal", %{conn: conn, user: user, recipe: recipe} do
      conn = authed(conn, user)
      {:ok, lv, _html} = live(conn, "/plan")

      html = render_click(lv, "open_slot", %{"slot_key" => "mon_dinner"})
      # modal title
      assert html =~ "Måndag · Middag"

      # eventually the recipe shows up either in suggested or all-recipes list
      :timer.sleep(150)
      html = render(lv)
      assert html =~ recipe.title
    end

    test "save with selected recipe fires assign and closes modal", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      conn = authed(conn, user)
      {:ok, lv, _html} = live(conn, "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "tue_dinner"})
      :timer.sleep(150)
      render_click(lv, "pick_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "save_slot", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert state.slots["tue_dinner"].recipe_id == recipe.id
    end

    test "leftover day chips create leftover events on save", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      conn = authed(conn, user)
      {:ok, lv, _html} = live(conn, "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "mon_dinner"})
      :timer.sleep(150)
      render_click(lv, "pick_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "toggle_leftover_day", %{"day" => "tue_dinner"})
      render_click(lv, "save_slot", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert state.slots["mon_dinner"].recipe_id == recipe.id
      assert state.slots["tue_dinner"].leftover == true
    end

    test "'No dinner planned' toggle saves as MealSkipped", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      # Pre-assign a meal so skip has something to act on
      Planning.assign_recipe(home_scope(), this_plan_id(), "wed_dinner", recipe.id, 4)

      conn = authed(conn, user)
      {:ok, lv, _html} = live(conn, "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "wed_dinner"})
      :timer.sleep(150)
      render_click(lv, "toggle_skipped", %{})
      render_click(lv, "save_slot", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert state.slots["wed_dinner"].skipped == true
    end

    test "marks an empty day as eating out with a place and amount", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "thu_dinner"})
      render_click(lv, "toggle_eating_out", %{})

      lv
      |> form("#eating-out-form", %{place: "Sushi", amount: "450"})
      |> render_submit()

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert Tore.Planning.State.eating_out?(state.slots["thu_dinner"])
      assert %{place: "Sushi", amount: "450"} = state.slots["thu_dinner"]

      assert lv |> element("#slot-thu_dinner") |> render() =~ "Äta ute"
    end

    test "eating out cancels the day's recipe and needs no amount", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      Planning.assign_recipe(home_scope(), this_plan_id(), "wed_dinner", recipe.id, 4)
      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "wed_dinner"})
      render_click(lv, "toggle_eating_out", %{})
      lv |> form("#eating-out-form", %{place: "", amount: ""}) |> render_submit()

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert %{recipe_id: nil, amount: nil} = state.slots["wed_dinner"]
    end

    test "the sheet shows what was saved, and can add an amount later", %{conn: conn, user: user} do
      Planning.eat_out(home_scope(), this_plan_id(), "thu_dinner", %{place: "Sushi"})

      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      html = render_click(lv, "open_slot", %{"slot_key" => "thu_dinner"})
      assert html =~ ~s(value="Sushi")

      lv |> form("#eating-out-form", %{place: "Sushi", amount: "300"}) |> render_submit()

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert %{place: "Sushi", amount: "300"} = state.slots["thu_dinner"]
    end

    test "'Not eating out' clears the day and its cost", %{conn: conn, user: user} do
      Planning.eat_out(home_scope(), this_plan_id(), "thu_dinner", %{amount: 300})

      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "thu_dinner"})
      render_click(lv, "clear_eating_out", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      refute Map.has_key?(state.slots, "thu_dinner")
    end

    test "picking a recipe replaces eating out", %{conn: conn, user: user, recipe: recipe} do
      Planning.eat_out(home_scope(), this_plan_id(), "thu_dinner", %{amount: 300})

      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "thu_dinner"})
      :timer.sleep(150)
      render_click(lv, "pick_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "save_slot", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert state.slots["thu_dinner"].recipe_id == recipe.id
      refute Tore.Planning.State.eating_out?(state.slots["thu_dinner"])
    end

    test "search_slot_recipes event updates search state", %{conn: conn, user: user} do
      conn = authed(conn, user)
      {:ok, lv, _html} = live(conn, "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "mon_dinner"})
      :timer.sleep(150)
      # drive the event directly rather than via form helper (avoids phx-click-away)
      html = render_change(lv, "search_slot_recipes", %{"q" => "salmon"})
      # modal still visible and search query reflected in input value
      assert html =~ ~s(value="salmon") or html =~ "salmon"
    end

    test "servings stepper bounded to 1..12", %{conn: conn, user: user} do
      conn = authed(conn, user)
      {:ok, lv, _html} = live(conn, "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "mon_dinner"})
      :timer.sleep(150)

      # default 4 → click dec 5 times, should land on 1
      for _ <- 1..5, do: render_click(lv, "dec_servings", %{})
      html = render(lv)
      # extract the displayed number — the modal renders portions as "1"
      assert html =~ ~r/>\s*1\s*<\/span>\s*<button[^>]*phx-click="inc_servings"/

      # click inc 20 times, should cap at 12
      for _ <- 1..20, do: render_click(lv, "inc_servings", %{})
      html = render(lv)
      assert html =~ ~r/>\s*12\s*<\/span>\s*<button[^>]*phx-click="inc_servings"/
    end

    test "slot sheet scoped command dispatches a run scoped to the touched slot", %{
      conn: conn,
      user: user
    } do
      conn = authed(conn, user)
      test_pid = self()

      Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, msgs, _tools, _opts ->
        send(test_pid, {:llm_messages, msgs})
        {:ok, {:message, "Done — made it vegetarian."}, %{}}
      end)

      {:ok, view, _} = live(conn, "/plan")

      view
      |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"]))
      |> render_click()

      view
      |> form(~s(form[phx-submit="slot_command"]), %{command: "make it vegetarian"})
      |> render_submit()

      assert_receive {:llm_messages, msgs}, 1000
      assert [%{role: "user", content: content}] = msgs
      assert content =~ "[The user is referring to"
      assert content =~ "mon_dinner"
      assert content =~ "make it vegetarian"

      # the modal closes after dispatch, same as close_slot
      refute has_element?(view, ~s(form[phx-submit="slot_command"]))

      # A run still writing after the test ends lands in the next test's database.
      assert eventually_renders(view, "Tore justerade planen")
    end
  end

  describe "planning the open days" do
    setup :fake_pi

    test "one button asks pi to plan what's still open, and what pi says streams in", %{
      conn: conn,
      user: user,
      pi_log: log
    } do
      System.put_env("FAKE_PI_REPLY", "Planerade resten av veckan.")
      {:ok, view, _} = live(authed(conn, user), "/plan")
      today = Tore.Clock.today()
      open = 8 - Date.day_of_week(today)

      button = view |> element(~s([data-role="plan-week"]))

      assert render(button) =~
               if(open == 1, do: "Planera 1 dag", else: "Planera #{open} dagar")

      html = render_click(button)
      assert html =~ "Planerar de lediga dagarna…"

      assert eventually_renders(view, "Planerade resten av veckan.")
      refute render(view) =~ "Planerar de lediga dagarna…"

      [header, %{"type" => "prompt", "message" => message}] = pi_records(log)
      assert header["session"] == "chat"
      assert message =~ "open days from #{Date.to_iso8601(today)}"
    end

    test "a household that may not use pi is told why", %{conn: conn, user: user} do
      Application.delete_env(:tore, :pi)
      {:ok, view, _} = live(authed(conn, user), "/plan")

      html = view |> element(~s([data-role="plan-week"])) |> render_click()
      assert html =~ "Tore kunde inte slutföra det."
      refute has_element?(view, ~s([data-role="pi-reply"]))
    end

    test "a week with every day planned has no button", %{conn: conn, user: user, recipe: recipe} do
      for day <- ~w(mon tue wed thu fri sat sun),
          do: Planning.assign_recipe(home_scope(), this_plan_id(), "#{day}_dinner", recipe.id, 4)

      {:ok, view, _} = live(authed(conn, user), "/plan")
      refute has_element?(view, ~s([data-role="plan-week"]))
    end
  end

  describe "opening a day and closing it again" do
    setup %{conn: conn, user: user, recipe: recipe} do
      Planning.assign_with_leftovers(home_scope(), this_plan_id(), "mon_dinner", recipe.id, 4, [
        "tue_dinner"
      ])

      %{conn: authed(conn, user)}
    end

    defp event_count do
      Tore.Repo.aggregate(Tore.EventStore.Event, :count, Tore.Scope.repo_opts(home_scope()))
    end

    test "writes nothing to the plan", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plan")
      before = event_count()

      render_click(lv, "open_slot", %{"slot_key" => "mon_dinner"})
      render_click(lv, "close_slot", %{})

      assert event_count() == before
    end

    test "leaves a leftover day's portions alone", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plan")

      render_click(lv, "open_slot", %{"slot_key" => "tue_dinner"})
      render_click(lv, "close_slot", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert %{servings: 2, leftover: true} = state.slots["tue_dinner"]
    end

    test "a leftover day with changed portions keeps them", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plan")

      render_click(lv, "open_slot", %{"slot_key" => "tue_dinner"})
      render_click(lv, "inc_servings", %{})
      render_click(lv, "close_slot", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert state.slots["tue_dinner"].servings == 3
    end
  end

  describe "a request from a day's sheet" do
    setup %{conn: conn, user: user} do
      %{conn: authed(conn, user)}
    end

    defp ask_about_monday(view, command) do
      view
      |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"]))
      |> render_click()

      view
      |> form(~s(form[phx-submit="slot_command"]), %{command: command})
      |> render_submit()
    end

    test "shows the question when Tore needs to ask", %{conn: conn} do
      Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
        {:ok,
         {:tool_calls,
          [%{id: "c1", name: "ask_user", args: %{"question" => "Which salmon recipe?"}}]}, %{}}
      end)

      {:ok, view, _} = live(conn, "/plan")
      ask_about_monday(view, "move the salmon")

      assert eventually_renders(view, "Which salmon recipe?")
    end

    test "says so when the request fails", %{conn: conn} do
      Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
        raise "boom"
      end)

      {:ok, view, _} = live(conn, "/plan")
      ask_about_monday(view, "skip it")

      assert eventually_renders(view, "Tore kunde inte slutföra det")
    end
  end

  describe "pinning a slot" do
    test "toggling pin in the modal persists a SlotPinned event", %{conn: conn, user: user} do
      conn = authed(conn, user)
      plan = this_plan_id()
      {:ok, lv, _html} = live(conn, "/plan")

      lv
      |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"]))
      |> render_click()

      lv |> element(~s(button[phx-click="toggle_pinned"])) |> render_click()

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert Map.has_key?(state.pins, "mon_dinner")
    end

    test "toggling pin off persists a SlotUnpinned event", %{conn: conn, user: user} do
      conn = authed(conn, user)
      plan = this_plan_id()
      Planning.pin_slot(home_scope(), plan, "mon_dinner", true)
      {:ok, lv, _html} = live(conn, "/plan")

      lv
      |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"]))
      |> render_click()

      lv |> element(~s(button[phx-click="toggle_pinned"])) |> render_click()

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      refute Map.has_key?(state.pins, "mon_dinner")
    end

    test "the day row shows a lock indicator when the slot is pinned", %{conn: conn, user: user} do
      conn = authed(conn, user)
      plan = this_plan_id()
      Planning.pin_slot(home_scope(), plan, "mon_dinner", true)
      {:ok, lv, _html} = live(conn, "/plan")

      # structural: the indicator lives inside the pinned slot's row, not just somewhere
      assert has_element?(lv, ~s(#slot-mon_dinner [data-pinned="true"]))
    end

    test "the day row shows no lock indicator when not pinned", %{conn: conn, user: user} do
      conn = authed(conn, user)
      {:ok, _lv, html} = live(conn, "/plan")
      refute html =~ ~s(data-pinned="true")
    end

    test "the pin toggle renders its Swedish label", %{conn: conn, user: user} do
      conn = authed(conn, user)
      {:ok, lv, _html} = live(conn, "/plan")

      html =
        lv
        |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"]))
        |> render_click()

      assert html =~ "Lås dagen"
    end

    test "opening an already-pinned slot shows the toggle in its 'on' state", %{
      conn: conn,
      user: user
    } do
      conn = authed(conn, user)
      plan = this_plan_id()
      Planning.pin_slot(home_scope(), plan, "mon_dinner", true)
      {:ok, lv, _html} = live(conn, "/plan")

      html =
        lv
        |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"]))
        |> render_click()

      # the modal's pin toggle reflects the pinned state: label "Låst", not "Lås dagen"
      assert html =~ "Låst"
      refute html =~ "Lås dagen"
    end
  end

  describe "focus param" do
    test "focus param highlights the named slot and not others", %{conn: conn, user: user} do
      conn = authed(conn, user)
      {:ok, _lv, html} = live(conn, "/plan?focus=mon_dinner")
      # the highlight ring is bound to the focused row's <li>, not just present somewhere
      assert html =~ ~r/id="slot-mon_dinner"[^>]*ring-2 ring-\[color:var\(--accent\)\]/
      # a non-focused slot's row carries no highlight ring
      refute html =~ ~r/id="slot-tue_dinner"[^>]*ring-2 ring-\[color:var\(--accent\)\]/
    end

    test "no focus param highlights nothing", %{conn: conn, user: user} do
      conn = authed(conn, user)
      {:ok, _lv, html} = live(conn, "/plan")
      refute html =~ "ring-2 ring-[color:var(--accent)]"
    end
  end

  defp eventually_renders(view, substr, attempts \\ 20)

  defp eventually_renders(view, substr, 0) do
    flunk(
      "Timed out waiting for #{inspect(substr)}.\nRendered:\n#{Phoenix.LiveViewTest.render(view)}"
    )
  end

  defp eventually_renders(view, substr, attempts) do
    if Phoenix.LiveViewTest.render(view) =~ substr do
      true
    else
      Process.sleep(25)
      eventually_renders(view, substr, attempts - 1)
    end
  end

  test "links to this week's prep", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> authed(user) |> live(~p"/plan")

    {:ok, _prep, html} =
      view
      |> element(~s(a[data-role="prep-link"]))
      |> render_click()
      |> follow_redirect(conn |> authed(user), ~p"/prep")

    assert html =~ "phx-click=\"generate_guide\""
  end

  describe "lunch" do
    # Next week: every day is still ahead. 2026-11-23..29 has no holiday.
    defp next_week do
      today = Tore.Clock.today()
      Date.add(today, 8 - Date.day_of_week(today))
    end

    defp lunch_rows(lv),
      do: lv |> render() |> then(&Regex.scan(~r/data-role="lunch"/, &1)) |> length()

    test "offered on the weekend, and on a day off, which says so", %{conn: conn, user: user} do
      {:ok, lv, _} = live(authed(conn, user), "/plan")
      render_click(lv, "next_week", %{})
      assert lunch_rows(lv) == 2

      :ok = Planning.mark_days_off(home_scope(), [Date.add(next_week(), 1)])
      {:ok, lv, _} = live(authed(conn, user), "/plan")
      render_click(lv, "next_week", %{})

      assert lunch_rows(lv) == 3
      assert has_element?(lv, "#slot-tue_dinner [data-role=day-off]", "Fridag")
    end

    test "+ Lunch plans one above the day's dinner", %{conn: conn, user: user, recipe: recipe} do
      {:ok, lv, _} = live(authed(conn, user), "/plan")
      render_click(lv, "next_week", %{})

      lv |> element("#slot-sat_dinner [data-role=lunch]") |> render_click()
      assert render(lv) =~ "Lördag · Lunch"
      refute has_element?(lv, "button", "Hoppa över middagen")
      assert has_element?(lv, "[data-role=add-lunch]") == false

      render_click(lv, "pick_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "close_slot", %{})

      {:ok, plan} = Planning.load_plan(home_scope(), Tore.Streams.plan(home_scope(), next_week()))
      assert %{recipe_id: id} = plan.slots["sat_lunch"]
      assert id == recipe.id
      refute Map.has_key?(plan.slots, "sat_dinner")
      assert has_element?(lv, "#slot-sat_dinner [data-role=lunch]", recipe.title)
    end

    test "any day's sheet adds one, and a lunch's sheet removes it", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      {:ok, lv, _} = live(authed(conn, user), "/plan")
      render_click(lv, "next_week", %{})
      refute has_element?(lv, "#slot-wed_dinner [data-role=lunch]")

      render_click(lv, "open_slot", %{"slot_key" => "wed_dinner"})
      lv |> element("[data-role=add-lunch]") |> render_click()
      assert render(lv) =~ "Onsdag · Lunch"

      render_click(lv, "pick_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "close_slot", %{})
      assert has_element?(lv, "#slot-wed_dinner [data-role=lunch]", recipe.title)

      render_click(lv, "open_slot", %{"slot_key" => "wed_lunch"})
      lv |> element("[data-role=remove-lunch]") |> render_click()

      {:ok, plan} = Planning.load_plan(home_scope(), Tore.Streams.plan(home_scope(), next_week()))
      refute Map.has_key?(plan.slots, "wed_lunch")
    end
  end
end
