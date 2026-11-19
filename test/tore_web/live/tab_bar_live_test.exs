defmodule ToreWeb.TabBarLiveTest do
  use ToreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    user = user_fixture(name: "Gustaf")
    %{conn: build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})}
  end

  defp bar(view), do: find_live_child(view, "tab-bar-live")

  test "every main screen has the tab bar, with Tore in the middle", %{conn: conn} do
    for path <- [~p"/today", ~p"/plan", ~p"/shop", ~p"/recipes", ~p"/settings"] do
      {:ok, view, _html} = live(conn, path)
      html = bar(view) |> element(~s([data-role="tab-bar"])) |> render()

      hrefs = Regex.scan(~r/href="([^"]+)"/, html) |> Enum.map(&List.last/1)

      assert ["/today", "/plan", "/capture" <> _, "/shop", "/recipes"] = hrefs,
             "unexpected tabs on #{path}: #{inspect(hrefs)}"
    end
  end

  test "marks the current tab; prep counts as the plan", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/today")

    render_hook(bar(view), "here", %{"path" => "/prep"})

    assert bar(view) |> element(~s([data-role="tab-bar"] a[aria-current="page"])) |> render() =~
             ~s(href="/plan")

    render_hook(bar(view), "here", %{"path" => "/settings"})
    refute has_element?(bar(view), ~s([data-role="tab-bar"] a[aria-current="page"]))
  end

  test "every tab is named, the current one's icon is filled, and nothing sparkles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/today")
    render_hook(bar(view), "here", %{"path" => "/plan"})
    html = render(bar(view))

    for label <- ["Idag", "Plan", "Tore", "Inköp", "Recept"], do: assert(html =~ label)

    assert bar(view) |> element(~s([data-role="tab-bar"] a[aria-current="page"])) |> render() =~
             "ph-calendar-blank-fill"

    refute html =~ "sparkles"
  end

  test "Tore opens the chat over the page, which it returns to, query string and all", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/recipes")
    render_hook(bar(view), "here", %{"path" => "/recipes", "search" => "?tag=fisk"})

    assert bar(view) |> element(~s([data-role="tab-tore"])) |> render() =~
             ~s(href="/capture?return_to=%2Frecipes%3Ftag%3Dfisk")
  end

  test "every tab's top bar has the menu, and Today no longer has a gear", %{conn: conn} do
    for path <- [~p"/today", ~p"/plan", ~p"/shop", ~p"/recipes"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, ~s([data-role="open-menu"])), "no menu on #{path}"
    end

    # Settings lives in the menu's foot now, not on the page.
    {:ok, view, _html} = live(conn, ~p"/today")
    refute view |> element("main") |> render() =~ "ph-gear-six"
  end

  describe "the menu" do
    setup do
      scope = home_scope()
      {:ok, stew} = Tore.Recipes.create(scope, %{title: "Kycklinggryta", recipe_type: :meal})
      {:ok, buns} = Tore.Recipes.create(scope, %{title: "Kanelbullar", recipe_type: :baking})
      :ok = Tore.Recipes.set_favorite(scope, buns.id, true)

      today = Tore.Clock.today()
      plan_id = Tore.Streams.plan(scope, Tore.Streams.monday(today))
      Tore.Planning.assign_recipe(scope, plan_id, Tore.Streams.slot_key(today), stew.id, 4)

      %{stew: stew, buns: buns}
    end

    test "opens on the rest of the week, the starred recipes, the collections and settings", %{
      conn: conn,
      stew: stew,
      buns: buns
    } do
      {:ok, view, _html} = live(conn, ~p"/plan")
      refute has_element?(bar(view), ~s([data-role="menu"]))

      render_hook(bar(view), "open_menu", %{})

      tonight =
        bar(view)
        |> element(~s([data-role="menu-day"].is-current[href="/recipes?id=#{stew.id}"]))
        |> render()

      assert tonight =~ "Kycklinggryta"
      assert tonight =~ "ikväll"

      days = Regex.scan(~r/data-role="menu-day"/, render(bar(view)))
      assert length(days) == 8 - Date.day_of_week(Tore.Clock.today())

      assert bar(view) |> element(~s([data-role="menu-favorite"])) |> render() =~ "Kanelbullar"

      assert has_element?(
               bar(view),
               ~s([data-role="menu-favorite"][href="/recipes?id=#{buns.id}"])
             )

      assert bar(view)
             |> element(~s([data-role="menu-collection"][href="/recipes?type=meal"]))
             |> render() =~ ~r/Middag.*1/s

      assert bar(view)
             |> element(~s([data-role="menu-collection"][href="/recipes?type=assembly"]))
             |> render() =~ ~r/>\s*0\s*</

      assert has_element?(bar(view), ~s([data-role="menu-settings"][href="/settings"]))

      # Ask Tore leads, under the household; Members and diet live inside Settings.
      menu = bar(view) |> element(~s([data-role="menu"])) |> render()
      [before_week, _] = String.split(menu, ~s(data-role="menu-day"), parts: 2)
      assert before_week =~ ~s(data-role="menu-ask")
      refute menu =~ "/settings#members"
      refute menu =~ "/settings#diet"
    end

    test "closes on the scrim, on Escape, and when a link is followed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/plan")

      for close <- [
            &render_click(&1, "close_menu", %{}),
            &render_keydown(&1, "close_menu", %{"key" => "Escape"}),
            &render_hook(&1, "here", %{"path" => "/recipes"})
          ] do
        render_hook(bar(view), "open_menu", %{})
        assert has_element?(bar(view), ~s([data-role="menu"]))
        close.(bar(view))
        refute has_element?(bar(view), ~s([data-role="menu"]))
      end
    end
  end

  describe "the sidebar, on a wide screen" do
    setup do
      {:ok, buns} =
        Tore.Recipes.create(home_scope(), %{title: "Kanelbullar", recipe_type: :baking})

      :ok = Tore.Recipes.set_favorite(home_scope(), buns.id, true)
      :ok
    end

    test "holds the tabs with Tore among them, and marks where you are", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/today")
      render_hook(bar(view), "here", %{"path" => "/recipes", "wide" => true})

      tabs =
        Regex.scan(
          ~r/data-role="side-tab"[^>]*href="([^"]+)"|href="([^"]+)"[^>]*data-role="side-tab"/,
          bar(view) |> element(~s([data-role="sidebar"])) |> render()
        )
        |> Enum.map(fn match -> Enum.find(tl(match), &(&1 != "")) end)

      assert tabs == ["/today", "/plan", "/capture?return_to=%2Frecipes", "/shop", "/recipes"]

      assert bar(view)
             |> element(~s([data-role="sidebar"] a[aria-current="page"]))
             |> render() =~ ~s(href="/recipes")

      # Settings sits alone at the foot; Tore is a row with the tabs, not a bar.
      refute has_element?(bar(view), ~s([data-role="sidebar"] [data-role="menu-ask"]))

      assert has_element?(
               bar(view),
               ~s([data-role="sidebar"] [data-role="side-foot"] [data-role="menu-settings"])
             )

      refute bar(view)
             |> element(~s([data-role="sidebar"] [data-role="menu-sections"]))
             |> render() =~ ~s(data-role="menu-settings")
    end

    test "shows the menu's sections, read again on every move", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/today")
      render_hook(bar(view), "here", %{"path" => "/today", "wide" => true})

      assert bar(view)
             |> element(~s([data-role="sidebar"] [data-role="menu-favorite"]))
             |> render() =~ "Kanelbullar"

      assert [_where_you_are] =
               Regex.scan(
                 ~r/is-current/,
                 bar(view) |> element(~s([data-role="sidebar"])) |> render()
               )

      {:ok, salsa} =
        Tore.Recipes.create(home_scope(), %{title: "Salsa verde", recipe_type: :component})

      :ok = Tore.Recipes.set_favorite(home_scope(), salsa.id, true)
      render_hook(bar(view), "here", %{"path" => "/plan", "wide" => true})
      assert render(bar(view)) =~ "Salsa verde"
    end

    test "a narrow screen reads nothing for it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/today")
      render_hook(bar(view), "here", %{"path" => "/today"})
      assert has_element?(bar(view), ~s([data-role="sidebar"]))
      refute has_element?(bar(view), ~s([data-role="sidebar"] [data-role="menu-favorite"]))
    end
  end

  test "a collection picked in the menu opens Recipes on it", %{conn: conn} do
    {:ok, _} = Tore.Recipes.create(home_scope(), %{title: "Salsa verde", recipe_type: :component})
    {:ok, _} = Tore.Recipes.create(home_scope(), %{title: "Pannkakor", recipe_type: :baking})

    {:ok, _view, html} = live(conn, ~p"/recipes?type=component")
    assert html =~ "Salsa verde"
    refute html =~ "Pannkakor"
  end
end
