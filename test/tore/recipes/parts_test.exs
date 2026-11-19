defmodule Tore.Recipes.PartsTest do
  use Tore.DataCase, async: false

  alias Tore.Recipes

  defp recipe(title, servings, ingredients, type \\ :component) do
    {:ok, recipe} =
      Recipes.create(
        home_scope(),
        %{
          title: title,
          base_servings: servings,
          recipe_type: type,
          ingredients:
            Enum.map(ingredients, fn {name, quantity, unit} ->
              %{name: name, quantity: quantity && Decimal.new(quantity), unit: unit}
            end)
        },
        image: false
      )

    recipe
  end

  defp amounts(recipe) do
    recipe.recipe_ingredients
    |> Enum.map(&{&1.ingredient.name, &1.quantity && Decimal.to_string(&1.quantity), &1.unit})
    |> Enum.sort()
  end

  setup do
    bearnaise =
      recipe("Bearnaise", 4, [{"Smör", "200", "g"}, {"Äggula", "3", "st"}, {"Dragon", nil, nil}])

    entrecote = recipe("Stekt entrecote", 2, [{"Entrecote", "400", "g"}, {"Smör", "20", "g"}])
    %{bearnaise: bearnaise, entrecote: entrecote}
  end

  test "a meal's ingredients are its parts', scaled to its servings and added up", %{
    bearnaise: bearnaise,
    entrecote: entrecote
  } do
    {:ok, meal} =
      Recipes.put_together(home_scope(), %{
        title: "Entrecote med bearnaise",
        servings: 4,
        part_ids: [entrecote.id, bearnaise.id]
      })

    assert meal.recipe_type == :meal
    assert Enum.map(meal.parts, & &1.title) == ["Stekt entrecote", "Bearnaise"]

    assert amounts(meal) == [
             {"Dragon", nil, nil},
             {"Entrecote", "800", "g"},
             {"Smör", "240", "g"},
             {"Äggula", "3", "st"}
           ]

    assert [loaded] = Recipes.get_many(home_scope(), [meal.id])
    assert amounts(loaded) == amounts(meal)
  end

  test "a meal needs two parts of the household's own, and a part can't have parts", %{
    bearnaise: bearnaise,
    entrecote: entrecote
  } do
    attrs = %{title: "Middag", servings: 4}

    assert {:error, :too_few_parts} =
             Recipes.put_together(home_scope(), Map.put(attrs, :part_ids, [bearnaise.id]))

    other = Tore.AccountsFixtures.scope_fixture(Tore.AccountsFixtures.household_fixture())

    assert {:error, :unknown_parts} =
             Recipes.put_together(other, Map.put(attrs, :part_ids, [bearnaise.id, entrecote.id]))

    {:ok, meal} =
      Recipes.put_together(home_scope(), Map.put(attrs, :part_ids, [bearnaise.id, entrecote.id]))

    assert {:error, :nested} =
             Recipes.put_together(
               home_scope(),
               %{title: "Mer", servings: 4, part_ids: [meal.id, bearnaise.id]}
             )
  end

  test "changing a part clears the cooking order of meals that have it", %{
    bearnaise: bearnaise,
    entrecote: entrecote
  } do
    {:ok, meal} =
      Recipes.put_together(home_scope(), %{
        title: "Entrecote med bearnaise",
        servings: 4,
        part_ids: [entrecote.id, bearnaise.id]
      })

    {:ok, _} = Recipes.update(home_scope(), meal, %{steps: Jason.encode!([%{"order" => 1}])})

    {:ok, _} =
      Recipes.update(home_scope(), Recipes.get!(home_scope(), bearnaise.id), %{
        ingredients: [%{name: "Smör", quantity: Decimal.new(250), unit: "g"}]
      })

    meal = Recipes.get!(home_scope(), meal.id)
    assert meal.steps == nil
    assert {"Smör", "290", "g"} in amounts(meal)
  end
end
