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

  describe "members" do
    defp add_member(view, username) do
      view |> form(~s(form[phx-submit="add_member"]), %{username: username}) |> render_submit()
    end

    test "adding someone who hasn't signed in says they join at their first sign-in", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = add_member(view, "bo")

      assert html =~ "bo går med vid sin första inloggning."
      assert html =~ "Går med vid första inloggningen"
    end

    test "adding someone already a member says so", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert add_member(view, user.username) =~ "Personen är redan medlem."
    end

    test "removing a member closes their open pages and their next request is elsewhere", %{
      conn: conn
    } do
      partner = user_fixture(name: "Partner")
      ToreWeb.Endpoint.subscribe("users_sessions:#{partner.id}")
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> element(~s(button[phx-click="remove_member"][phx-value-id="#{partner.id}"]))
        |> render_click()

      refute html =~ "Partner"
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      {_partner, scope} = Tore.Accounts.get_session(partner.id)
      assert scope.household_id != home_scope().household_id
    end

    test "the switcher appears only for someone in two or more households", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      refute has_element?(view, ~s(button[phx-click="switch_household"]))

      # Home holds something, so being added elsewhere adds a household rather than moving them.
      Tore.Repo.insert!(%Tore.Recipes.Recipe{
        household_id: home_scope().household_id,
        title: "Ärtsoppa",
        recipe_type: :meal
      })

      other = household_fixture(%{name: "Stugan"})
      {:ok, {:added, _}} = Tore.Members.add(scope_fixture(other), user.username)
      {:ok, view, html} = live(conn, ~p"/settings")
      assert html =~ "Dina hushåll"

      view
      |> element(~s(button[phx-click="switch_household"][phx-value-id="#{other.id}"]))
      |> render_click()

      assert {_user, %{household_id: id}} = Tore.Accounts.get_session(user.id)
      assert id == other.id
    end

    test "renames the household", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form(~s(form[phx-submit="rename_household"]), %{name: "Rydholms"})
      |> render_submit()

      assert home_household().name == "Rydholms"
    end
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
