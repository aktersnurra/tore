defmodule Tore.Shop.PantryRulesTest do
  use Tore.DataCase, async: false

  alias Tore.{Recipes, Shop}
  alias Tore.Pantry.Learn
  alias Tore.Recipes.Ingredient

  # No `stub`: any model call on these paths fails the test.

  defp list_id, do: Tore.Streams.shop_list(home_scope(), ~D[2026-04-27])

  defp ingredient(name, category) do
    %Ingredient{household_id: home_scope().household_id}
    |> Ingredient.changeset(%{name: name, category: category})
    |> Repo.insert!()
  end

  defp items do
    {:ok, state} = Shop.load_list(home_scope(), list_id())
    state.items |> Map.values() |> Map.new(&{&1.name, &1.section})
  end

  test "a known name is sorted into its ingredient's section with no model" do
    ingredient("Mjölk", "dairy")

    assert Shop.section_for(home_scope(), "mjölk") == :dairy
    assert Shop.section_for(home_scope(), "Okänt") == :other
  end

  test "adding an item asks no model" do
    ingredient("Mjölk", "dairy")
    {:ok, _} = Shop.add_item(home_scope(), list_id(), "Mjölk", nil, nil, 1)
    {:ok, _} = Shop.add_item(home_scope(), list_id(), "Kaffe", nil, nil, 1)

    assert items() == %{"Mjölk" => :dairy, "Kaffe" => :other}
  end

  test "a learned name moves its waiting items to their section" do
    {:ok, _} = Shop.add_item(home_scope(), list_id(), "Kaffe", nil, nil, 1)
    {:ok, _} = Shop.add_item(home_scope(), list_id(), "Bröd", nil, nil, 1)

    # Their ingredients, as written (no pi here), then what pi says of them (learn_ingredients).
    assert :ok = Learn.names(home_scope(), ["Kaffe", "Bröd"])

    for {name, section} <- [{"Kaffe", "beverages"}, {"Bröd", "bread"}] do
      assert :filled =
               Learn.learn(home_scope(), %{
                 name: name,
                 same_as: nil,
                 section: section,
                 shelf_life_days: nil
               })
    end

    assert :ok = Shop.resettle_sections(home_scope(), list_id())

    assert items() == %{"Kaffe" => :beverages, "Bröd" => :bread}
  end

  test "building the list leaves out what the pantry holds, by ingredient, with no model" do
    ingredient("Mjölk", "dairy")

    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: "Pannkakor",
        recipe_type: :meal,
        ingredients: [
          %{name: "Mjölk", quantity: 6, unit: "dl"},
          %{name: "Vetemjöl", quantity: 3, unit: "dl"},
          %{name: "Ägg", quantity: 3, unit: "st"}
        ]
      })

    {:ok, _, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{catalogue_name: "Ägg", provenance: "manual"})

    items = Shop.items_for(home_scope(), [recipe.id], Tore.Streams.monday(Tore.Clock.today()))

    assert items |> Enum.map(&{&1.name, &1.section}) |> Enum.sort() ==
             [{"Mjölk", :dairy}, {"Vetemjöl", :other}]
  end

  test "an item past its date in the pantry is bought again" do
    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: "Ostmacka",
        recipe_type: :meal,
        ingredients: [%{name: "Ost", quantity: 1, unit: "st"}]
      })

    {:ok, _} =
      Tore.Pantry.add_item(home_scope(), %{
        name: "ost",
        expires_at: Date.add(Tore.Clock.today(), -1)
      })

    assert [%{name: "Ost"}] =
             Shop.items_for(home_scope(), [recipe.id], Tore.Streams.monday(Tore.Clock.today()))
  end
end
