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

  test "Today links to Settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/today")
    assert has_element?(view, ~s(a[data-role="settings-link"][href="/settings"]))
  end
end
