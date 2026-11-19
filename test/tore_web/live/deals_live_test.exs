defmodule ToreWeb.DealsLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.{Basics, Deals, Shop, Streams}
  alias Tore.Prices.Products

  setup do
    user = user_fixture(name: "Tester")
    %{conn: Plug.Test.init_test_session(build_conn(), %{user_id: user.id})}
  end

  defp use_store(name) do
    store = Tore.Repo.insert!(%Deals.Store{name: name, url: "https://example.test/#{name}"})

    Tore.Repo.insert!(%Deals.HouseholdStore{
      household_id: home_scope().household_id,
      store_id: store.id
    })
  end

  defp offer(name, price, regular, attrs \\ %{}) do
    {:ok, _} =
      Deals.upsert_deals([
        Map.merge(
          %{
            chain: "ica",
            store: "ICA Maxi",
            product_name: name,
            price: Decimal.new(price),
            regular_price: regular && Decimal.new(regular),
            valid_until: Date.add(Tore.Clock.today(), 2)
          },
          attrs
        )
      ])
  end

  defp usual(product, ingredient) do
    :ok = Basics.ask(home_scope(), [%{name: ingredient}])

    id =
      Tore.Repo.get_by!(
        Tore.Recipes.Ingredient,
        [name: ingredient],
        Tore.Scope.repo_opts(home_scope())
      ).id

    :ok = Products.put(home_scope(), product, id)
  end

  defp list_names do
    {:ok, %{items: items}} =
      Shop.load_list(
        home_scope(),
        Streams.shop_list(home_scope(), Streams.monday(Tore.Clock.today()))
      )

    items |> Map.values() |> Enum.map(& &1.name)
  end

  test "the saving first, what's usually bought open, the rest folded", %{conn: conn} do
    use_store("ICA Maxi")
    offer("MELLANMJÖLK", "30", "18.90", %{quantity: 2, size: "1,5 l"})
    offer("Chips", "20", "29")
    usual("MELLANMJÖLK", "Mjölk")

    {:ok, view, _} = live(conn, ~p"/deals")

    assert view |> element("[data-role=headline]") |> render() =~ "8 kr"
    assert has_element?(view, "[data-role=group-usual][open]", "MELLANMJÖLK")
    assert has_element?(view, "[data-role=group-usual]", "2 för 30")
    assert has_element?(view, "[data-role=group-usual]", "18,90/st")
    assert has_element?(view, "[data-role=group-others]:not([open])", "Chips")
    refute has_element?(view, "[data-role=group-dinners]")
  end

  test "+ puts the ingredient on this week's list, once", %{conn: conn} do
    use_store("ICA Maxi")
    offer("MELLANMJÖLK", "30", "18.90", %{quantity: 2})
    usual("MELLANMJÖLK", "Mjölk")

    {:ok, view, _} = live(conn, ~p"/deals")
    view |> element("[data-role=add-deal]") |> render_click()

    assert list_names() == ["Mjölk"]
    assert has_element?(view, "[data-role=on-list]")
    refute has_element?(view, "[data-role=add-deal]")
  end

  test "an offer nothing matched goes on the list by its own name", %{conn: conn} do
    use_store("ICA Maxi")
    offer("Chips", "20", "29")

    {:ok, view, _} = live(conn, ~p"/deals")
    view |> element("[data-role=add-deal]") |> render_click()

    assert list_names() == ["Chips"]
  end

  test "without stores it says where offers come from", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/deals")
    assert view |> element("[data-role=headline]") |> render() =~ "Erbjudanden från butikerna"
  end

  test "with stores but nothing in yet it says when they come", %{conn: conn} do
    use_store("ICA Maxi")
    {:ok, _view, html} = live(conn, ~p"/deals")
    assert html =~ "fredag"
  end
end
