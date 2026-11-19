defmodule ToreWeb.DealsLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.{Basics, Deals, Shop, Streams}
  alias Tore.Prices.Products

  setup do
    user = user_fixture(name: "Tester")
    %{conn: Plug.Test.init_test_session(build_conn(), %{user_id: user.id})}
  end

  @store_url "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  defp add_store(view, url) do
    if has_element?(view, "[data-role=add-store]"),
      do: view |> element("[data-role=add-store]") |> render_click()

    view |> form(~s(form[phx-submit="add_store"]), %{url: url}) |> render_submit()
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
    refute has_element?(view, "[data-role=group-meals]")
    assert has_element?(view, "[data-role=store]", "2 erbjudanden")
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

  describe "stores" do
    test "another household's store can't be switched off or removed", %{conn: conn} do
      other = scope_fixture(household_fixture())
      {:ok, theirs} = Deals.add_store(other, @store_url)
      {:ok, view, _html} = live(conn, ~p"/deals")

      render_click(view, "toggle_store", %{"id" => to_string(theirs.id)})
      render_click(view, "remove_store", %{"id" => to_string(theirs.id)})

      assert render(view) =~ "Erbjudanden"
      assert [%{scrape_enabled: true}] = Deals.list_stores(other)
    end

    test "adds a store from just a link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deals")

      assert add_store(view, @store_url) =~ "ICA Supermarket Danvikstull"

      assert [%{store: %{url: @store_url}, scrape_enabled: true}] =
               Deals.list_stores(home_scope())
    end

    test "says so when it can't read a store", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deals")

      assert add_store(view, "https://www.coop.se/butiker/x/") =~
               "Tore kan inte läsa den butiken än"

      assert Deals.list_stores(home_scope()) == []
    end

    test "says so when a store is already added", %{conn: conn} do
      {:ok, _} = Deals.add_store(home_scope(), @store_url)
      {:ok, view, _html} = live(conn, ~p"/deals")

      assert add_store(view, @store_url) =~ "Den butiken är redan tillagd"
      assert [_] = Deals.list_stores(home_scope())
    end

    test "switches a store off and on", %{conn: conn} do
      {:ok, _} = Deals.add_store(home_scope(), @store_url)
      {:ok, view, _html} = live(conn, ~p"/deals")

      view |> element(~s(button[phx-click="toggle_store"])) |> render_click()
      refute hd(Deals.list_stores(home_scope())).scrape_enabled

      view |> element(~s(button[phx-click="toggle_store"])) |> render_click()
      assert hd(Deals.list_stores(home_scope())).scrape_enabled
    end

    test "removes a store", %{conn: conn} do
      {:ok, _} = Deals.add_store(home_scope(), @store_url)
      {:ok, view, _html} = live(conn, ~p"/deals")

      refute view |> element(~s(button[phx-click="remove_store"])) |> render_click() =~
               "ICA Supermarket Danvikstull"

      assert Deals.list_stores(home_scope()) == []
    end
  end
end
