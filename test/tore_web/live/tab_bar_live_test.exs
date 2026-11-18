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
      html = render(bar(view))

      hrefs = Regex.scan(~r/href="([^"]+)"/, html) |> Enum.map(&List.last/1)

      assert ["/today", "/plan", "/capture" <> _, "/shop", "/recipes"] = hrefs,
             "unexpected tabs on #{path}: #{inspect(hrefs)}"
    end
  end

  test "marks the current tab; prep counts as the plan", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/today")

    render_hook(bar(view), "here", %{"path" => "/prep"})
    assert bar(view) |> element(~s(a[aria-current="page"])) |> render() =~ ~s(href="/plan")

    render_hook(bar(view), "here", %{"path" => "/settings"})
    refute has_element?(bar(view), ~s(a[aria-current="page"]))
  end

  test "every tab is named, the current one's icon is filled, and nothing sparkles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/today")
    render_hook(bar(view), "here", %{"path" => "/plan"})
    html = render(bar(view))

    for label <- ["Idag", "Plan", "Tore", "Inköp", "Recept"], do: assert(html =~ label)

    assert bar(view) |> element(~s(a[aria-current="page"])) |> render() =~
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

    {:ok, view, _html} = live(conn, ~p"/today")
    refute render(view) =~ "ph-gear-six"
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

  test "a collection picked in the menu opens Recipes on it", %{conn: conn} do
    {:ok, _} = Tore.Recipes.create(home_scope(), %{title: "Salsa verde", recipe_type: :component})
    {:ok, _} = Tore.Recipes.create(home_scope(), %{title: "Pannkakor", recipe_type: :baking})

    {:ok, _view, html} = live(conn, ~p"/recipes?type=component")
    assert html =~ "Salsa verde"
    refute html =~ "Pannkakor"
  end
end
