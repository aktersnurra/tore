defmodule ToreWeb.ShopScannerTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias Tore.{Pantry, Repo, Shop}
  alias Tore.Pantry.Match
  alias Tore.Recipes.Ingredient

  setup :set_mox_global
  setup :verify_on_exit!

  @milk "7310865004703"

  setup do
    user = user_fixture(name: "Tester")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})

    milk =
      %Ingredient{household_id: home_scope().household_id}
      |> Ingredient.changeset(%{name: "Mjölk", category: "dairy"})
      |> Repo.insert!()

    %{conn: conn, milk: milk}
  end

  defp list_id, do: Tore.Streams.shop_list(home_scope(), Tore.Streams.monday(Tore.Clock.today()))

  defp eventually(view, text, tries \\ 40) do
    cond do
      render(view) =~ text -> true
      tries == 0 -> flunk("#{inspect(text)} never showed")
      true -> Process.sleep(25) && eventually(view, text, tries - 1)
    end
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/shop")
    view |> element("button[phx-click=open_scanner]") |> render_click()
    view
  end

  defp scan(view, code),
    do: view |> element("#scanner") |> render_hook("scanned", %{"code" => code})

  test "a known pack goes into the pantry, and can be undone", %{conn: conn, milk: milk} do
    :ok =
      Match.learn_alias(home_scope(), {:barcode, @milk}, milk.id, %{
        quantity: Decimal.new(1),
        unit: "l"
      })

    view = open(conn)
    assert render(view) =~ "Håll en streckkod i rutan."

    scan(view, @milk)
    assert eventually(view, "Mjölk finns i skafferiet")
    assert [%{name: "mjölk"}] = Pantry.list_inventory(home_scope())

    view |> element("#scanner-lines button", "Ångra") |> render_click()
    assert eventually(view, "Ångrat.")
    assert Pantry.list_inventory(home_scope()) == []
  end

  test "a pack on the list is ticked off", %{conn: conn, milk: milk} do
    :ok = Match.learn_alias(home_scope(), {:barcode, @milk}, milk.id)
    {:ok, _} = Shop.add_item(home_scope(), list_id(), "mjölk", nil, nil, nil)
    view = open(conn)

    scan(view, @milk)
    assert eventually(view, "mjölk bockad av listan")

    {:ok, state} = Shop.load_list(home_scope(), list_id())
    assert [%{checked: true}] = Map.values(state.items)
  end

  test "a code nobody knows is named once", %{conn: conn} do
    expect(Tore.MockHTTP, :fetch, fn _ -> {:error, {:http_error, 404}} end)
    view = open(conn)

    scan(view, @milk)
    assert eventually(view, "Tore känner inte igen koden. Vad är det?")

    view |> form("#scanner-name", %{"name" => "mjölk"}) |> render_submit()
    assert eventually(view, "Mjölk finns i skafferiet")
    assert {:ok, %Ingredient{name: "Mjölk"}} = Match.ingredient(home_scope(), {:barcode, @milk})
  end

  test "a camera Tore can't use says so", %{conn: conn} do
    view = open(conn)
    view |> element("#scanner") |> render_hook("scanner_failed", %{"reason" => "NotAllowedError"})
    assert render(view) =~ "Tore kommer inte åt kameran"
  end

  test "closing the scanner takes it away", %{conn: conn} do
    view = open(conn)
    view |> element("button[phx-click=close_scanner]") |> render_click()
    refute has_element?(view, "#scanner")
  end
end
