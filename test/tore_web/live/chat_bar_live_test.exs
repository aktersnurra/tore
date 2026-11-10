defmodule ToreWeb.ChatBarLiveTest do
  use ToreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tore.RunFixtures

  alias Tore.Harness.Runs
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Kinds

  setup do
    user = user_fixture(name: "Gustaf")
    %{conn: build_conn() |> Plug.Test.init_test_session(%{user_id: user.id}), user: user}
  end

  defp bar(view), do: find_live_child(view, "chat-bar")

  defp store_pick(swaps) do
    {:ok, _} =
      Runs.submit(
        home_scope(),
        Kinds.HomePick,
        %HomePick{screen: :today, source: :model, swaps: swaps},
        %{}
      )
  end

  test "every screen has the chat bar and no other navigation", %{conn: conn} do
    for path <- [~p"/today", ~p"/plan", ~p"/shop", ~p"/recipes", ~p"/settings"] do
      {:ok, view, html} = live(conn, path)
      assert bar(view), "no chat bar on #{path}"
      refute html =~ ~s(data-role="bottom-nav")
      assert render(bar(view)) =~ ~s(data-role="chat-bar")
    end
  end

  test "shows the stored pick's swaps, leaving out the one for the page shown", %{conn: conn} do
    store_pick([:open_plan, :open_shop])
    {:ok, view, _html} = live(conn, ~p"/today")

    assert bar(view) |> element(~s([data-role="swaps"])) |> render() =~ "Veckans plan"

    render_hook(bar(view), "here", %{"path" => "/plan"})
    swaps = bar(view) |> element(~s([data-role="swaps"])) |> render()
    refute swaps =~ "Veckans plan"
    assert swaps =~ "Inköpslistan"
  end

  test "an open swap navigates to its screen", %{conn: conn} do
    store_pick([:open_shop])
    {:ok, view, _html} = live(conn, ~p"/today")

    assert {:error, {:live_redirect, %{to: "/shop"}}} =
             bar(view) |> element(~s([data-role="swap"]), "Inköpslistan") |> render_click()
  end

  test "a prompt swap opens Capture with its request, returning to the page", %{
    conn: conn
  } do
    store_pick([:plan_next_week])
    {:ok, view, _html} = live(conn, ~p"/plan")
    render_hook(bar(view), "here", %{"path" => "/plan"})

    assert {:error, {:live_redirect, %{to: to}}} =
             bar(view) |> element(~s([data-role="swap"]), "Planera nästa vecka") |> render_click()

    assert to == ~p"/capture?#{[q: "Planera nästa vecka", return_to: "/plan"]}"
  end

  test "the chat box sends what was typed to Capture", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/shop")
    render_hook(bar(view), "here", %{"path" => "/shop"})

    assert {:error, {:live_redirect, %{to: to}}} =
             bar(view) |> form("form", %{"message" => "  lägg till mjölk "}) |> render_submit()

    assert to == ~p"/capture?#{[q: "lägg till mjölk", return_to: "/shop"]}"
  end

  test "the menu lists every page and the reviews waiting", %{conn: conn} do
    pending_review_fixture(home_scope())
    {:ok, view, _html} = live(conn, ~p"/today")

    refute has_element?(bar(view), ~s([data-role="menu"]))
    bar(view) |> element(~s([data-role="menu-button"])) |> render_click()

    menu = bar(view) |> element(~s([data-role="menu"])) |> render()

    for path <-
          ~w(/today /plan /shop /recipes /prep /cooking /review /settings/costs /settings/pantry /settings) do
      assert menu =~ ~s(href="#{path}"), "menu has no #{path}"
    end

    assert menu =~ "Granska (1)"
  end

  test "a Capture turn's swaps replace the pick's until the next pick", %{conn: conn, user: user} do
    store_pick([:open_plan])
    {:ok, view, _html} = live(conn, ~p"/today")

    Phoenix.PubSub.broadcast(
      Tore.PubSub,
      Tore.Home.swaps_topic(user.id),
      {:quick_swaps, [%{label: "Mer pasta", action: {:prompt, "Mer pasta"}}]}
    )

    assert render(bar(view)) =~ "Mer pasta"
    refute render(bar(view)) =~ "Veckans plan"

    store_pick([:open_shop])
    html = render(bar(view))
    refute html =~ "Mer pasta"
    assert html =~ "Inköpslistan"
  end
end
