defmodule Tore.DealsPageTest do
  use Tore.DataCase, async: false

  alias Tore.{Basics, Deals, Planning, Recipes, Shop, Streams}
  alias Tore.Prices.Products

  defp d(s), do: Decimal.new(s)

  setup do
    store = Repo.insert!(%Deals.Store{name: "ICA Maxi", url: "https://example.test/maxi"})

    Repo.insert!(%Deals.HouseholdStore{
      household_id: home_scope().household_id,
      store_id: store.id
    })

    %{today: Tore.Clock.today(), week: Streams.monday(Tore.Clock.today())}
  end

  defp offer(name, price, regular, attrs \\ %{}) do
    {:ok, _} =
      Deals.upsert_deals([
        Map.merge(
          %{
            chain: "ica",
            store: "ICA Maxi",
            product_name: name,
            price: price && d(price),
            regular_price: regular && d(regular),
            valid_until: Date.add(Tore.Clock.today(), 2)
          },
          attrs
        )
      ])
  end

  # Tonight's dinner calls for `ingredient`.
  defp dinner_tonight(title, ingredient) do
    {:ok, recipe} =
      Recipes.create(
        home_scope(),
        %{title: title, base_servings: 4, ingredients: [%{name: ingredient, quantity: 1}]},
        image: false
      )

    today = Tore.Clock.today()

    {:ok, _} =
      Planning.assign_recipe(
        home_scope(),
        Streams.plan(home_scope(), Streams.monday(today)),
        Streams.slot_key(today),
        recipe.id,
        4
      )

    ingredient_id(ingredient)
  end

  defp ingredient_id(name),
    do: Repo.get_by!(Recipes.Ingredient, [name: name], Tore.Scope.repo_opts(home_scope())).id

  defp names(entries), do: Enum.map(entries, & &1.name)

  test "deals fall into tonight's dinners, what's usually bought and the rest", %{
    today: today,
    week: week
  } do
    chicken = dinner_tonight("Kycklinggryta", "Kycklinglårfilé")
    :ok = Basics.ask(home_scope(), [%{name: "Mjölk"}])

    offer("KYCKLINGLÅRFILÉ 900G", "89", "119")
    offer("MELLANMJÖLK 1,5L", "30", "18.90", %{quantity: 2})
    offer("Chips", "20", "29")
    :ok = Products.put(home_scope(), "KYCKLINGLÅRFILÉ 900G", chicken)
    :ok = Products.put(home_scope(), "MELLANMJÖLK 1,5L", ingredient_id("Mjölk"))

    page = Deals.page(home_scope(), week, today)

    assert [%{name: "Kycklinglårfilé", dinner: "Kycklinggryta", saving: saved}] = page.dinners
    assert Decimal.eq?(saved, 30)
    assert [%{name: "Mjölk", dinner: nil, saving: milk}] = page.usual
    assert Decimal.eq?(milk, "7.80")
    assert names(page.others) == ["Chips"]
    assert Decimal.eq?(page.saving, "37.80")
  end

  test "two offers on one ingredient save once, the better one", %{today: today, week: week} do
    :ok = Basics.ask(home_scope(), [%{name: "Kaffe"}])
    offer("Kaffe Zoégas", "59", "79")
    offer("Kaffe Gevalia", "49", "59")

    for p <- ["Kaffe Zoégas", "Kaffe Gevalia"],
        do: Products.put(home_scope(), p, ingredient_id("Kaffe"))

    page = Deals.page(home_scope(), week, today)

    assert length(page.usual) == 2
    assert Decimal.eq?(page.saving, 20)
  end

  test "a deal without a regular price saves nothing and comes last", %{today: today, week: week} do
    offer("Bröd", "25", nil)
    offer("Ost", "80", "100")

    assert [%{name: "Ost"}, %{name: "Bröd", saving: nil}] =
             Deals.page(home_scope(), week, today).others
  end

  test "says which deals are open on this week's list", %{today: today, week: week} do
    offer("Chips", "20", "29")
    offer("Ost", "80", "100")

    {:ok, _} =
      Shop.add_item(home_scope(), Streams.shop_list(home_scope(), week), "chips", nil, nil, nil)

    on_list = Map.new(Deals.page(home_scope(), week, today).others, &{&1.name, &1.on_list?})
    assert on_list == %{"Chips" => true, "Ost" => false}
  end

  test "counts each store's deals; a store switched off has none", %{today: today, week: week} do
    offer("Chips", "20", "29")
    offer("Ost", "80", "100")

    assert [%{store: %{store: %{name: "ICA Maxi"}}, deals: 2}] =
             Deals.page(home_scope(), week, today).stores

    [hs] = Deals.list_stores(home_scope())
    {:ok, _} = Deals.toggle_scraping(home_scope(), hs.id)

    page = Deals.page(home_scope(), week, today)
    assert [%{deals: 0}] = page.stores
    assert page.others == []
  end
end
