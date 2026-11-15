defmodule ToreWeb.SettingsDietTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.Household

  setup do
    user = user_fixture(name: "Tester")
    %{conn: Plug.Test.init_test_session(build_conn(), %{user_id: user.id})}
  end

  test "Settings sets the diet and allergies every plan is checked against", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "Vegetarisk"
    assert html =~ "Nötter"

    view
    |> element(~s(button[phx-click="toggle_allergy"][phx-value-item="nuts"]))
    |> render_click()

    view
    |> element(~s(button[phx-click="toggle_restriction"][phx-value-item="vegan"]))
    |> render_click()

    assert %{allergies: ["nuts"], dietary_restrictions: ["vegan"]} =
             Household.get_preferences(home_scope())

    view
    |> element(~s(button[phx-click="toggle_allergy"][phx-value-item="nuts"]))
    |> render_click()

    assert %{allergies: []} = Household.get_preferences(home_scope())
  end
end
