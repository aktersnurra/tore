defmodule ToreWeb.SettingsLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.{Accounts, Deals}

  setup do
    {:ok, {user, _code}} = Accounts.create_admin("Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  @store_url "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  defp add_store(view, url) do
    view |> form(~s(form[phx-submit="add_store"]), %{url: url}) |> render_submit()
  end

  test "settings no longer links to run history", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    refute html =~ "Körhistorik"
  end

  test "adds a store from just a link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert add_store(view, @store_url) =~ "ICA Supermarket Danvikstull"
    assert [%{url: @store_url, scrape_enabled: true}] = Deals.list_store_configs()
  end

  test "says so when it can't read a store", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert add_store(view, "https://www.coop.se/butiker/x/") =~
             "Tore kan inte läsa den butiken än"

    assert Deals.list_store_configs() == []
  end

  test "says so when a store is already added", %{conn: conn} do
    {:ok, _} = Deals.add_store(@store_url)
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert add_store(view, @store_url) =~ "Den butiken är redan tillagd"
    assert [_] = Deals.list_store_configs()
  end

  test "switches a store off and on", %{conn: conn} do
    {:ok, store} = Deals.add_store(@store_url)
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element(~s(button[phx-click="toggle_store"])) |> render_click()
    refute Deals.get_store_config!(store.id).scrape_enabled

    view |> element(~s(button[phx-click="toggle_store"])) |> render_click()
    assert Deals.get_store_config!(store.id).scrape_enabled
  end

  test "removes a store", %{conn: conn} do
    {:ok, _} = Deals.add_store(@store_url)
    {:ok, view, _html} = live(conn, ~p"/settings")

    refute view |> element(~s(button[phx-click="remove_store"])) |> render_click() =~
             "ICA Supermarket Danvikstull"

    assert Deals.list_store_configs() == []
  end

  test "the household's language is shown and can't be changed", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "Svenska"
    refute has_element?(view, ~s(select[name="locale"]))
    refute has_element?(view, ~s(form[phx-change="update_locale"]))
  end
end
