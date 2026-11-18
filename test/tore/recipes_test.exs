defmodule Tore.RecipesTest do
  use Tore.DataCase, async: false
  import Mox
  alias Tore.Recipes
  alias Tore.Recipes.Ingredient

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Recipes.generate_image/2 calls Tore.LLM.text to write an image-gen
    # prompt before invoking the image gen stub. Any prompt-string is fine
    # for these tests.
    stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, %{"prompt" => "A plate of food."}, %{}}
    end)

    :ok
  end

  defp recipe_attrs(overrides \\ %{}) do
    Map.merge(%{title: "Test Recipe", recipe_type: :meal}, overrides)
  end

  describe "generate_image/2" do
    test "stores the S3 object key in image_path, not a URL" do
      Tore.Storage.Mock.reset()
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())

      :ok = Recipes.generate_image(home_scope(), recipe, nil)

      reloaded = Recipes.get!(home_scope(), recipe.id)

      assert String.starts_with?(
               reloaded.image_path,
               "households/#{home_scope().household_id}/recipes/#{recipe.id}/"
             )

      assert String.ends_with?(reloaded.image_path, ".jpg")
      refute String.contains?(reloaded.image_path, "://")
    end

    test "broadcasts {:recipe_image, id, key} on the recipes topic" do
      Tore.Storage.Mock.reset()
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())
      Phoenix.PubSub.subscribe(Tore.PubSub, Recipes.topic(home_scope()))

      :ok = Recipes.generate_image(home_scope(), recipe, nil)

      assert_receive {:recipe_image, recipe_id, key}
      assert recipe_id == recipe.id

      assert String.starts_with?(
               key,
               "households/#{home_scope().household_id}/recipes/#{recipe.id}/"
             )
    end
  end

  describe "scale_quantity/3" do
    test "scales to the servings, whole numbers from 10, one decimal below" do
      assert Recipes.scale_quantity(Decimal.new(200), 4, 6) == Decimal.new(300)
      assert Recipes.scale_quantity(Decimal.new(1), 4, 6) == Decimal.new("1.5")
      assert Recipes.scale_quantity(Decimal.new(3), 4, 1) == Decimal.new("0.8")
      assert Recipes.scale_quantity(Decimal.new(125), 4, 3) == Decimal.new(94)
      assert Recipes.scale_quantity(Decimal.new("2.5"), 4, 4) == Decimal.new("2.5")
      assert Recipes.scale_quantity(nil, 4, 6) == nil
      assert Recipes.scale_quantity(Decimal.new(2), nil, 6) == Decimal.new(2)
    end
  end

  describe "the house style" do
    test "every picture is the dish as described, taken the same way" do
      bun = Tore.LLM.Prompts.food_photo("Cinnamon buns with pearl sugar in a tin. ")
      sauce = Tore.LLM.Prompts.food_photo("A jar of béarnaise with a spoon lifted from it.")

      assert String.starts_with?(bun, "Cinnamon buns with pearl sugar in a tin.\n\n")
      style = fn prompt -> prompt |> String.split("\n\n", parts: 2) |> List.last() end
      assert style.(bun) == style.(sauce)
      assert style.(bun) =~ "cast-iron"
    end

    test "restyle_images draws every recipe again and counts them" do
      Tore.Storage.Mock.reset()
      {:ok, a} = Recipes.create(home_scope(), recipe_attrs(%{title: "A"}), image: false)
      {:ok, _b} = Recipes.create(home_scope(), recipe_attrs(%{title: "B"}), image: false)

      assert %{drawn: 2, failed: 0} = Recipes.restyle_images()
      assert Recipes.get!(home_scope(), a.id).image_path
    end

    test "draw_missing_pictures draws only the recipes without one, and only where it's on" do
      Tore.Storage.Mock.reset()
      {:ok, bare} = Recipes.create(home_scope(), recipe_attrs(%{title: "A"}), image: false)
      {:ok, drawn} = Recipes.create(home_scope(), recipe_attrs(%{title: "B"}), image: false)
      :ok = Recipes.generate_image(home_scope(), drawn, nil)
      had = Recipes.get!(home_scope(), drawn.id).image_path

      assert %{drawn: 0, failed: 0} = Recipes.draw_missing_pictures()
      refute Recipes.get!(home_scope(), bare.id).image_path

      Application.put_env(:tore, :draw_missing_pictures, true)
      on_exit(fn -> Application.put_env(:tore, :draw_missing_pictures, false) end)

      assert %{drawn: 1, failed: 0} = Recipes.draw_missing_pictures()
      assert Recipes.get!(home_scope(), bare.id).image_path
      assert Recipes.get!(home_scope(), drawn.id).image_path == had
    end
  end

  describe "create/1" do
    test "inserts a basic recipe" do
      assert {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())
      assert recipe.title == "Test Recipe"
      assert recipe.recipe_type == :meal
    end

    test "inserts recipe with tags" do
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs(%{tags: ["quick", "batch"]}))
      tag_names = Enum.map(recipe.tags, & &1.name)
      assert "quick" in tag_names
      assert "batch" in tag_names
    end

    test "upserts ingredients — no duplicate names" do
      {:ok, _} = Recipes.create(home_scope(), recipe_attrs(%{ingredients: [%{name: "garlic"}]}))

      {:ok, _} =
        Recipes.create(
          home_scope(),
          recipe_attrs(%{title: "Recipe 2", ingredients: [%{name: "garlic"}]})
        )

      assert Repo.aggregate(Tore.Recipes.Ingredient, :count, Tore.Scope.repo_opts(home_scope())) ==
               1
    end

    test "inserts recipe with ingredients" do
      attrs = recipe_attrs(%{ingredients: [%{name: "onion", quantity: 2, unit: "pcs"}]})
      {:ok, recipe} = Recipes.create(home_scope(), attrs)
      assert length(recipe.recipe_ingredients) == 1
      ri = hd(recipe.recipe_ingredients)
      assert ri.ingredient.name == "onion"
    end

    test "returns error for missing title" do
      assert {:error, changeset} = Recipes.create(home_scope(), %{})
      assert %{title: [_ | _]} = errors_on(changeset)
    end
  end

  describe "update/2" do
    test "updates fields" do
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())

      {:ok, updated} =
        Recipes.update(home_scope(), recipe, %{title: "Updated", prep_time_minutes: 15})

      assert updated.title == "Updated"
      assert updated.prep_time_minutes == 15
    end

    test "replaces tags" do
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs(%{tags: ["quick"]}))
      {:ok, updated} = Recipes.update(home_scope(), recipe, %{tags: ["batch", "vegetarian"]})
      tag_names = Enum.map(updated.tags, & &1.name)
      assert "batch" in tag_names
      assert "vegetarian" in tag_names
      refute "quick" in tag_names
    end

    test "nil tags leaves existing tags unchanged" do
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs(%{tags: ["quick"]}))
      {:ok, updated} = Recipes.update(home_scope(), recipe, %{title: "New title"})
      tag_names = Enum.map(updated.tags, & &1.name)
      assert "quick" in tag_names
    end
  end

  describe "update/2 with ingredients" do
    test "replaces all ingredients on update" do
      {:ok, recipe} =
        Recipes.create(home_scope(), %{
          title: "Soup",
          recipe_type: :meal,
          ingredients: [%{name: "Water", quantity: "1", unit: "L"}]
        })

      {:ok, updated} =
        Recipes.update(home_scope(), recipe, %{
          ingredients: [
            %{name: "Chicken", quantity: "500", unit: "g"},
            %{name: "Salt", quantity: "1", unit: "tsp"}
          ]
        })

      names = Enum.map(updated.recipe_ingredients, & &1.ingredient.name)
      assert length(updated.recipe_ingredients) == 2
      assert "Chicken" in names
      assert "Salt" in names
      refute "Water" in names
    end

    test "clears all ingredients when passed empty list" do
      {:ok, recipe} =
        Recipes.create(home_scope(), %{
          title: "Soup",
          recipe_type: :meal,
          ingredients: [%{name: "Water", quantity: "1", unit: "L"}]
        })

      {:ok, updated} = Recipes.update(home_scope(), recipe, %{ingredients: []})
      assert updated.recipe_ingredients == []
    end

    test "does not touch ingredients when key is absent" do
      {:ok, recipe} =
        Recipes.create(home_scope(), %{
          title: "Soup",
          recipe_type: :meal,
          ingredients: [%{name: "Water", quantity: "1", unit: "L"}]
        })

      {:ok, updated} = Recipes.update(home_scope(), recipe, %{title: "Updated Soup"})
      assert length(updated.recipe_ingredients) == 1
      assert hd(updated.recipe_ingredients).ingredient.name == "Water"
    end
  end

  describe "list/1" do
    setup do
      {:ok, r1} =
        Recipes.create(home_scope(), %{
          title: "Alpha",
          recipe_type: :meal,
          prep_time_minutes: 10,
          cook_time_minutes: 20,
          tags: ["quick"]
        })

      {:ok, r2} =
        Recipes.create(home_scope(), %{
          title: "Beta",
          recipe_type: :component,
          prep_time_minutes: 5,
          cook_time_minutes: 60,
          tags: ["batch"]
        })

      {:ok, r3} =
        Recipes.create(home_scope(), %{
          title: "Gamma",
          recipe_type: :assembly,
          prep_time_minutes: 5,
          cook_time_minutes: 10,
          tags: ["quick", "vegetarian"]
        })

      %{r1: r1, r2: r2, r3: r3}
    end

    test "returns all recipes by default" do
      assert length(Recipes.list(home_scope())) == 3
    end

    test "filters by single tag" do
      results = Recipes.list(home_scope(), tags: ["quick"])
      titles = Enum.map(results, & &1.title)
      assert "Alpha" in titles
      assert "Gamma" in titles
      refute "Beta" in titles
    end

    test "filters by multiple tags (AND)" do
      results = Recipes.list(home_scope(), tags: ["quick", "vegetarian"])
      assert length(results) == 1
      assert hd(results).title == "Gamma"
    end

    test "filters by type" do
      results = Recipes.list(home_scope(), type: :component)
      assert length(results) == 1
      assert hd(results).title == "Beta"
    end

    test "filters by max_minutes" do
      results = Recipes.list(home_scope(), max_minutes: 30)
      titles = Enum.map(results, & &1.title)
      assert "Alpha" in titles
      assert "Gamma" in titles
      refute "Beta" in titles
    end

    test "weeknight_friendly: quick tag + ≤45 min" do
      results = Recipes.list(home_scope(), weeknight_friendly: true)
      titles = Enum.map(results, & &1.title)
      assert "Alpha" in titles
      assert "Gamma" in titles
      refute "Beta" in titles
    end

    test "sorts alphabetically" do
      results = Recipes.list(home_scope(), sort: :alphabetical)
      titles = Enum.map(results, & &1.title)
      assert titles == Enum.sort(titles)
    end

    test "starred recipes come first, whatever the order", %{r3: r3} do
      :ok = Recipes.set_favorite(home_scope(), r3.id, true)

      for sort <- [:alphabetical, :last_used, :recently_added] do
        assert [%{title: "Gamma"} | _] = Recipes.list(home_scope(), sort: sort)
      end

      assert [%{title: "Gamma"}] = Recipes.list_favorites(home_scope())
    end
  end

  describe "search/1" do
    setup do
      {:ok, _} = Recipes.create(home_scope(), %{title: "Chicken Soup", recipe_type: :meal})

      {:ok, _} =
        Recipes.create(home_scope(), %{
          title: "Pasta",
          recipe_type: :meal,
          ingredients: [%{name: "garlic"}]
        })

      :ok
    end

    test "matches by title" do
      results = Recipes.search(home_scope(), "chicken")
      assert length(results) == 1
      assert hd(results).title == "Chicken Soup"
    end

    test "matches by ingredient name" do
      results = Recipes.search(home_scope(), "garlic")
      assert length(results) == 1
      assert hd(results).title == "Pasta"
    end

    test "returns empty list for no match" do
      assert [] = Recipes.search(home_scope(), "xyz123notarecipe")
    end

    test "returns empty list for empty query" do
      assert [] = Recipes.search(home_scope(), "")
    end
  end

  describe "cook_steps/2" do
    test "are the recipe's own steps, in order, without asking the model" do
      steps = [
        %{"phase" => "COOKING", "order" => 2, "action" => "Fry", "ingredients" => []},
        %{"phase" => "MISE EN PLACE", "order" => 1, "action" => "Chop", "ingredients" => []}
      ]

      {:ok, recipe} =
        Recipes.create(home_scope(), Map.put(recipe_attrs(), :steps, Jason.encode!(steps)))

      assert {:ok, [%{"action" => "Chop"}, %{"action" => "Fry"}]} =
               Recipes.cook_steps(home_scope(), recipe)
    end

    test "are written once for a recipe that only has running text, then kept" do
      {:ok, recipe} =
        Recipes.create(home_scope(), Map.put(recipe_attrs(), :instructions, "Chop. Then fry."))

      expect(Tore.MockLLM, :text, 1, fn _system, user, _opts ->
        assert user =~ "Chop. Then fry."

        {:ok,
         %{
           "steps" => [
             %{
               "phase" => "MISE EN PLACE",
               "order" => 1,
               "action" => "Chop",
               "ingredients" => [],
               "duration_minutes" => nil
             },
             %{
               "phase" => "COOKING",
               "order" => 2,
               "action" => "Fry",
               "ingredients" => [],
               "duration_minutes" => 5
             }
           ]
         }, %{}}
      end)

      assert {:ok, [%{"action" => "Chop"}, %{"action" => "Fry"}]} =
               Recipes.cook_steps(home_scope(), recipe)

      # The second time they come from the recipe.
      assert {:ok, [_, _]} =
               Recipes.cook_steps(home_scope(), Recipes.get!(home_scope(), recipe.id))
    end

    test "say so when the model can't be reached" do
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())
      expect(Tore.MockLLM, :text, fn _system, _user, _opts -> {:error, :timeout} end)

      assert {:error, :timeout} = Recipes.cook_steps(home_scope(), recipe)
    end
  end

  describe "record_used/1" do
    test "sets last_used_at" do
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())
      assert is_nil(recipe.last_used_at)
      :ok = Recipes.record_used(home_scope(), recipe.id)
      updated = Recipes.get!(home_scope(), recipe.id)
      refute is_nil(updated.last_used_at)
    end
  end

  describe "delete/1" do
    test "removes the recipe" do
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())
      {:ok, _} = Recipes.delete(home_scope(), recipe)
      assert_raise Ecto.NoResultsError, fn -> Recipes.get!(home_scope(), recipe.id) end
    end
  end

  describe "Ingredient.to_key/1" do
    test "lowercases and replaces spaces with underscores" do
      assert Ingredient.to_key("Gul Lök") == "gul_lok"
    end

    test "normalises Swedish characters" do
      assert Ingredient.to_key("lök") == "lok"
      assert Ingredient.to_key("räkor") == "rakor"
      assert Ingredient.to_key("grädde") == "gradde"
      assert Ingredient.to_key("åkerbär") == "akerbar"
    end

    test "strips punctuation" do
      assert Ingredient.to_key("salt & peppar") == "salt__peppar"
      assert Ingredient.to_key("mjöl (vetemjöl)") == "mjol_vetemjol"
    end

    test "collapses separators" do
      assert Ingredient.to_key("olja/fett") == "olja_fett"
      assert Ingredient.to_key("smör - till stekning") == "smor_till_stekning"
    end
  end

  describe "ingredient key on create" do
    test "key is auto-derived from name" do
      {:ok, recipe} =
        Recipes.create(home_scope(), recipe_attrs(%{ingredients: [%{name: "Gul Lök"}]}))

      ingredient = hd(recipe.recipe_ingredients).ingredient
      assert ingredient.key == "gul_lok"
    end

    test "two recipes sharing an ingredient share the same key" do
      {:ok, _} = Recipes.create(home_scope(), recipe_attrs(%{ingredients: [%{name: "vitlök"}]}))

      {:ok, _} =
        Recipes.create(
          home_scope(),
          recipe_attrs(%{title: "Recipe 2", ingredients: [%{name: "vitlök"}]})
        )

      ingredients = Repo.all(Ingredient, Tore.Scope.repo_opts(home_scope()))
      keys = Enum.map(ingredients, & &1.key)
      assert keys == ["vitlok"]
    end
  end

  describe "catalog_fingerprints/0" do
    test "returns titles with their ingredient names" do
      Tore.Storage.Mock.reset()

      {:ok, _} =
        Recipes.create(
          home_scope(),
          recipe_attrs(%{
            title: "Miso Ramen",
            base_servings: 4,
            ingredients: [%{name: "miso paste"}, %{name: "ramen noodles"}]
          })
        )

      assert [%{title: "Miso Ramen", ingredient_names: names}] =
               Recipes.catalog_fingerprints(home_scope())

      assert Enum.sort(names) == ["miso paste", "ramen noodles"]
    end
  end

  describe "households" do
    test "a new recipe image is broadcast only to its own household" do
      Tore.Storage.Mock.reset()
      other = scope_fixture(household_fixture())
      {:ok, recipe} = Recipes.create(home_scope(), recipe_attrs())
      Phoenix.PubSub.subscribe(Tore.PubSub, Recipes.topic(other))

      :ok = Recipes.generate_image(home_scope(), recipe, nil)

      refute_received {:recipe_image, _, _}
    end

    test "a household sees only its own recipes" do
      other = scope_fixture(household_fixture())
      {:ok, mine} = Recipes.create(home_scope(), recipe_attrs(%{title: "Ärtsoppa"}))
      {:ok, theirs} = Recipes.create(other, recipe_attrs(%{title: "Pannkakor"}))

      assert Enum.map(Recipes.list(home_scope()), & &1.id) == [mine.id]
      assert Recipes.search(home_scope(), "Pannkakor") == []
      assert Recipes.get(home_scope(), theirs.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Recipes.get!(home_scope(), theirs.id) end
      assert_raise FunctionClauseError, fn -> Recipes.delete(home_scope(), theirs) end
      assert Recipes.get!(other, theirs.id)
    end

    test "two households can each have an ingredient with the same name" do
      other = scope_fixture(household_fixture())
      attrs = recipe_attrs(%{ingredients: [%{name: "vitlök"}]})

      {:ok, mine} = Recipes.create(home_scope(), attrs)
      {:ok, theirs} = Recipes.create(other, attrs)

      [%{ingredient: mine_ing}] = Recipes.get!(home_scope(), mine.id).recipe_ingredients
      [%{ingredient: their_ing}] = Recipes.get!(other, theirs.id).recipe_ingredients
      assert mine_ing.id != their_ing.id
      assert mine_ing.household_id == home_scope().household_id
      assert their_ing.household_id == other.household_id
    end
  end
end
