defmodule Tore.Mcp.RecipeToolsTest do
  @moduledoc "pi refining a saved recipe: update_recipe and draw_recipe_picture, each with undo."
  use Tore.DataCase, async: false

  import Tore.FakePi

  alias Tore.{Mcp, Recipes}
  alias Tore.Harness.{KitchenRun, Runs}

  defp call(name, args) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

    {:reply, %{"result" => result}} = Mcp.handle(home_scope(), request)
    result
  end

  defp ok(name, args) do
    assert %{"isError" => false, "structuredContent" => content} = call(name, args)
    content |> Jason.encode!() |> Jason.decode!()
  end

  defp soup do
    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: "Köttsoppa",
        recipe_type: :meal,
        base_servings: 4,
        image_path: "old.jpg",
        steps:
          Jason.encode!([
            %{
              "phase" => "KOK",
              "order" => 1,
              "action" => "Koka köttet.",
              "ingredients" => ["Kött"]
            }
          ]),
        ingredients: [%{name: "Kött", quantity: Decimal.new(500), unit: "g"}]
      })

    recipe
  end

  test "a recipe read with get_recipe, changed and sent back, is the new recipe; undo puts it back" do
    soup = soup()
    Phoenix.PubSub.subscribe(Tore.PubSub, Recipes.topic(home_scope()))

    vegetarian =
      ok("get_recipe", %{"recipe_id" => soup.id})
      |> Map.merge(%{
        "title" => "Linssoppa",
        "ingredients" => [%{"item" => "Röda linser", "quantity" => 3, "unit" => "dl"}],
        "steps" => [
          %{"phase" => "KOK", "order" => 1, "action" => "Koka linserna.", "ingredients" => []}
        ]
      })

    result = ok("update_recipe", vegetarian)
    assert %KitchenRun{actor: :mcp, status: :applied} = Runs.get(home_scope(), result["run_id"])
    assert_received {:recipe_changed, id} when id == soup.id

    changed = Recipes.get!(home_scope(), soup.id)
    assert changed.title == "Linssoppa"
    assert changed.image_path == "old.jpg"
    assert [%{ingredient: %{name: "Röda linser"}}] = changed.recipe_ingredients
    assert [%{"action" => "Koka linserna."}] = Recipes.cook_steps(changed)

    ok("undo", %{"run_id" => result["run_id"]})

    back = Recipes.get!(home_scope(), soup.id)
    assert back.title == "Köttsoppa"
    assert [%{ingredient: %{name: "Kött"}}] = back.recipe_ingredients
    assert [%{"action" => "Koka köttet."}] = Recipes.cook_steps(back)
  end

  test "a change that makes it a copy of another recipe, or of none, is refused" do
    soup = soup()

    {:ok, _} =
      Recipes.create(home_scope(), %{
        title: "Linssoppa",
        recipe_type: :meal,
        ingredients: [%{name: "Röda linser", quantity: nil, unit: nil}]
      })

    copy =
      ok("get_recipe", %{"recipe_id" => soup.id})
      |> Map.merge(%{
        "title" => "Linssoppa",
        "ingredients" => [%{"item" => "Röda linser", "quantity" => nil, "unit" => nil}]
      })

    assert %{"isError" => true, "content" => [%{"text" => text}]} = call("update_recipe", copy)
    assert text =~ "near_duplicate"
    assert Recipes.get!(home_scope(), soup.id).title == "Köttsoppa"

    assert %{"isError" => true} =
             call("update_recipe", Map.put(copy, "recipe_id", 0) |> Map.put("title", "Ny"))
  end

  describe "draw_recipe_picture" do
    setup :fake_pi

    test "draws the dish in the house style and sets it; undo puts the old picture back" do
      Tore.Storage.Mock.reset()
      soup = soup()

      result =
        ok("draw_recipe_picture", %{"recipe_id" => soup.id, "dish" => "Clear soup in a bowl."})

      assert_received {:image_prompt, prompt}
      assert prompt =~ "Clear soup in a bowl."

      new = Recipes.get!(home_scope(), soup.id).image_path
      assert new =~ ~r"recipes/#{soup.id}/.+\.jpg\z"

      ok("undo", %{"run_id" => result["run_id"]})
      assert Recipes.get!(home_scope(), soup.id).image_path == "old.jpg"
    end
  end

  test "no picture is drawn for a household without AI" do
    soup = soup()

    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             call("draw_recipe_picture", %{"recipe_id" => soup.id, "dish" => "Soup."})

    assert text =~ "off"
    refute_received {:image_prompt, _}
  end
end
