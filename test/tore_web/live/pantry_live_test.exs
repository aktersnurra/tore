defmodule ToreWeb.PantryLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Tore.Pantry

  setup do
    user = user_fixture(name: "Tester")
    %{conn: build_conn(), user: user}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "renders empty pantry", %{conn: conn, user: user} do
    conn = authed(conn, user)
    {:ok, _lv, html} = live(conn, "/settings/pantry")
    assert html =~ "Inget i skafferiet än"
  end

  test "renders existing items", %{conn: conn, user: user} do
    conn = authed(conn, user)

    {:ok, _} =
      Pantry.add_item(home_scope(), %{name: "Havregryn", quantity: Decimal.new("500"), unit: "g"})

    {:ok, _lv, html} = live(conn, "/settings/pantry")
    assert html =~ "Havregryn"
    assert html =~ "500"
  end

  test "old /pantry route no longer exists", %{conn: conn} do
    conn = get(conn, "/pantry")
    assert conn.status == 404
  end

  test "remove_item removes a pantry item", %{conn: conn, user: user} do
    conn = authed(conn, user)

    {:ok, item} =
      Tore.Pantry.add_item(home_scope(), %{
        name: "olive oil",
        quantity: Decimal.new(1),
        unit: "bottle"
      })

    {:ok, view, _html} = live(conn, "/settings/pantry")
    assert render(view) =~ "Olive oil"

    view |> element("button[phx-value-id=\"#{item.id}\"]") |> render_click()
    refute render(view) =~ "Olive oil"
  end

  test "a guessed date is marked approximate, and setting one moves the item's belief", %{
    conn: conn,
    user: user
  } do
    conn = authed(conn, user)

    {:ok, item, :added, _} =
      Pantry.upsert_belief(home_scope(), %{
        name: "mjölk",
        provenance: "manual",
        shelf_life_days: 7
      })

    {:ok, lv, html} = live(conn, "/settings/pantry")
    assert html =~ Date.to_iso8601(Date.add(Date.utc_today(), 7))
    assert html =~ "ungefär"
    assert html =~ "Bekräftat hemma"

    html =
      lv
      |> form("#expiry-#{item.id}", %{
        "expires_at" => Date.to_iso8601(Date.add(Date.utc_today(), -1))
      })
      |> render_change()

    refute html =~ "ungefär"
    assert html =~ "Okänd"

    assert Tore.Repo.get!(Tore.Pantry.PantryItem, item.id, Tore.Scope.repo_opts(home_scope())).expires_source ==
             "manual"
  end

  test "clearing the date removes it", %{conn: conn, user: user} do
    conn = authed(conn, user)

    {:ok, item, :added, _} =
      Pantry.upsert_belief(home_scope(), %{
        name: "mjölk",
        provenance: "manual",
        shelf_life_days: 7
      })

    {:ok, lv, _html} = live(conn, "/settings/pantry")
    lv |> form("#expiry-#{item.id}", %{"expires_at" => ""}) |> render_change()

    assert Tore.Repo.get!(Tore.Pantry.PantryItem, item.id, Tore.Scope.repo_opts(home_scope())).expires_at ==
             nil
  end
end
