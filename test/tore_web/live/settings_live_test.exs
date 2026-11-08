defmodule ToreWeb.SettingsLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.Deals

  setup do
    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  @store_url "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  defp add_store(view, url) do
    view |> form(~s(form[phx-submit="add_store"]), %{url: url}) |> render_submit()
  end

  test "lists the members, with no codes or roles", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "Gustaf"
    assert html =~ user.username
    refute has_element?(view, ~s(button[phx-click="regenerate_code"]))
    refute has_element?(view, ~s(form[phx-submit="add_user"]))
  end

  test "has a way to sign out", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, ~s(a[href="/logout"][data-method="delete"]))
  end

  test "settings no longer links to run history", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    refute html =~ "Körhistorik"
  end

  test "adds a store from just a link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert add_store(view, @store_url) =~ "ICA Supermarket Danvikstull"
    assert [%{store: %{url: @store_url}, scrape_enabled: true}] = Deals.list_stores(home_scope())
  end

  test "says so when it can't read a store", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert add_store(view, "https://www.coop.se/butiker/x/") =~
             "Tore kan inte läsa den butiken än"

    assert Deals.list_stores(home_scope()) == []
  end

  test "says so when a store is already added", %{conn: conn} do
    {:ok, _} = Deals.add_store(home_scope(), @store_url)
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert add_store(view, @store_url) =~ "Den butiken är redan tillagd"
    assert [_] = Deals.list_stores(home_scope())
  end

  test "switches a store off and on", %{conn: conn} do
    {:ok, _} = Deals.add_store(home_scope(), @store_url)
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element(~s(button[phx-click="toggle_store"])) |> render_click()
    refute hd(Deals.list_stores(home_scope())).scrape_enabled

    view |> element(~s(button[phx-click="toggle_store"])) |> render_click()
    assert hd(Deals.list_stores(home_scope())).scrape_enabled
  end

  test "removes a store", %{conn: conn} do
    {:ok, _} = Deals.add_store(home_scope(), @store_url)
    {:ok, view, _html} = live(conn, ~p"/settings")

    refute view |> element(~s(button[phx-click="remove_store"])) |> render_click() =~
             "ICA Supermarket Danvikstull"

    assert Deals.list_stores(home_scope()) == []
  end

  test "the household's language is shown and can't be changed", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "Svenska"
    refute has_element?(view, ~s(select[name="locale"]))
    refute has_element?(view, ~s(form[phx-change="update_locale"]))
  end
end
