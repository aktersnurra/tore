defmodule ToreWeb.PlannerLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

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
    today = Date.utc_today()
    dow = Date.day_of_week(today)
    week_start = Date.add(today, -(dow - 1))
    Tore.Streams.plan(home_scope(), week_start)
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

      entry = Tore.Costs.get_dining_out(this_plan_id(), "thu_dinner")
      assert entry.description == "Sushi"
      assert Decimal.equal?(entry.total_amount, 450)

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
      assert state.slots["wed_dinner"].recipe_id == nil
      assert Tore.Costs.get_dining_out(this_plan_id(), "wed_dinner").total_amount == nil
    end

    test "the sheet shows what was saved, and can add an amount later", %{conn: conn, user: user} do
      Planning.eat_out(home_scope(), this_plan_id(), "thu_dinner", %{
        description: "Sushi",
        user_id: user.id
      })

      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      html = render_click(lv, "open_slot", %{"slot_key" => "thu_dinner"})
      assert html =~ ~s(value="Sushi")

      lv |> form("#eating-out-form", %{place: "Sushi", amount: "300"}) |> render_submit()

      assert Decimal.equal?(
               Tore.Costs.get_dining_out(this_plan_id(), "thu_dinner").total_amount,
               300
             )
    end

    test "'Not eating out' clears the day and the cost entry", %{conn: conn, user: user} do
      Planning.eat_out(home_scope(), this_plan_id(), "thu_dinner", %{user_id: user.id})

      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "thu_dinner"})
      render_click(lv, "clear_eating_out", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      refute Map.has_key?(state.slots, "thu_dinner")
      assert Tore.Costs.get_dining_out(this_plan_id(), "thu_dinner") == nil
    end

    test "picking a recipe replaces eating out", %{conn: conn, user: user, recipe: recipe} do
      Planning.eat_out(home_scope(), this_plan_id(), "thu_dinner", %{user_id: user.id})

      {:ok, lv, _html} = live(authed(conn, user), "/plan")
      render_click(lv, "open_slot", %{"slot_key" => "thu_dinner"})
      :timer.sleep(150)
      render_click(lv, "pick_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "save_slot", %{})

      {:ok, state} = Planning.load_plan(home_scope(), this_plan_id())
      assert state.slots["thu_dinner"].recipe_id == recipe.id
      assert Tore.Costs.get_dining_out(this_plan_id(), "thu_dinner") == nil
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

  describe "command bar" do
    setup %{conn: conn, user: user} do
      %{conn: authed(conn, user)}
    end

    test "quick command renders a final message", %{conn: conn} do
      Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
        {:ok, {:message, "Done — skipped Monday dinner."}, %{}}
      end)

      {:ok, view, _} = live(conn, "/plan")

      view
      |> form("form[phx-submit=quick_command]", %{command: "skip mon dinner"})
      |> render_submit()

      assert eventually_renders(view, "Tore justerade planen")
    end

    test "quick command renders an ask_user question", %{conn: conn} do
      Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
        {:ok,
         {:tool_calls,
          [%{id: "c1", name: "ask_user", args: %{"question" => "Which salmon recipe?"}}]}, %{}}
      end)

      {:ok, view, _} = live(conn, "/plan")

      view
      |> form("form[phx-submit=quick_command]", %{command: "move the salmon"})
      |> render_submit()

      assert eventually_renders(view, "Which salmon recipe?")
    end

    test "quick command surfaces a flash when dispatch raises", %{conn: conn} do
      Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
        raise "boom"
      end)

      {:ok, view, _} = live(conn, "/plan")

      view
      |> form("form[phx-submit=quick_command]", %{command: "skip mon dinner"})
      |> render_submit()

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
end
