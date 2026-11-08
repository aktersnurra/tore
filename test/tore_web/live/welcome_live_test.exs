defmodule ToreWeb.WelcomeLiveTest do
  use ToreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tore.{Accounts, Household}

  setup do
    # Signs in with no pending membership, so they get a household of their own with no language.
    {:ok, user} =
      Accounts.sign_in(%{"sub" => "new-sub", "preferred_username" => "ny", "name" => "Ny"})

    {_user, scope} = Accounts.get_session(user.id)
    %{user: user, scope: scope}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "a household with no language sends its members to /welcome", %{conn: conn, user: user} do
    assert {:error, {:redirect, %{to: "/welcome"}}} = live(authed(conn, user), ~p"/recipes")
  end

  test "picking a language sets it for the household and the person, then goes home", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    {:ok, view, html} = live(authed(conn, user), ~p"/welcome")
    assert html =~ "Välkommen till Tore"

    view |> element(~s(button[phx-value-locale="en"])) |> render_click()

    assert_redirect(view, ~p"/")
    assert Household.locale(scope) == "en"
    assert {%{locale: "en"}, _} = Accounts.get_session(user.id)
  end

  test "a household with a language goes straight home from /welcome", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    {:ok, _} = Household.set_locale(scope, "sv")

    assert {:error, {:live_redirect, %{to: "/"}}} = live(authed(conn, user), ~p"/welcome")
  end

  test "members who joined before it was picked get the household's language too", %{
    user: user,
    scope: scope
  } do
    {:ok, {:pending, _}} = Tore.Members.add(scope, "partner")

    {:ok, partner} =
      Accounts.sign_in(%{"sub" => "partner-sub", "preferred_username" => "partner"})

    {:ok, _} = Household.set_locale(scope, "en")

    assert {%{locale: "en"}, _} = Accounts.get_session(user.id)
    assert {%{locale: "en"}, _} = Accounts.get_session(partner.id)
  end

  test "the language is picked once", %{scope: scope} do
    assert {:ok, _} = Household.set_locale(scope, "en")
    assert {:error, :already_set} = Household.set_locale(scope, "sv")
    assert {:error, :invalid_locale} = Household.set_locale(scope, "de")
    assert Household.locale(scope) == "en"
  end
end
