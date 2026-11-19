defmodule Tore.Pantry.LearnTest do
  @moduledoc "New names, learned by pi afterwards: list_ingredients, learn_ingredients and the job."
  use Tore.DataCase, async: false

  import Tore.FakePi

  alias Tore.{Mcp, Pantry}
  alias Tore.Pantry.{Learn, Match}
  alias Tore.Recipes.Ingredient

  defp ingredient(scope, attrs) do
    %Ingredient{household_id: scope.household_id}
    |> Ingredient.changeset(attrs)
    |> Repo.insert!()
  end

  defp tick(scope, name) do
    Tore.Harness.Runs.start(scope, Tore.Harness.Kinds.PantryUpdate, %{
      channel: :grocery_checkoff,
      items: [%{name: name, quantity: 1, unit: "l"}]
    })
  end

  defp tool(name, args) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

    {:reply, %{"result" => %{"isError" => false, "structuredContent" => content}}} =
      Mcp.handle(home_scope(), request)

    content |> Jason.encode!() |> Jason.decode!()
  end

  defp learned(items), do: tool("learn_ingredients", %{"items" => items})

  test "list_ingredients names the household's ingredients, with their sections" do
    ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})
    ingredient(home_scope(), %{name: "Gräddfil"})

    assert tool("list_ingredients", %{}) == %{
             "ingredients" => [
               %{"name" => "Gräddfil", "section" => nil, "price_guess" => nil},
               %{"name" => "Mjölk", "section" => "dairy", "price_guess" => nil}
             ]
           }
  end

  test "a new name pi says is an ingredient Tore has is merged into it, once" do
    scope = home_scope()
    milk = ingredient(scope, %{name: "Mjölk", category: "dairy"})
    {:ok, _} = tick(scope, "Mellanmjölk")

    assert %{"merged" => 1} =
             learned([%{"name" => "Mellanmjölk", "same_as" => "Mjölk", "section" => "dairy"}])

    assert [%{ingredient_id: id, name: "mjölk"}] = Pantry.list_inventory(scope)
    assert id == milk.id
    assert {:ok, %Ingredient{id: ^id}} = Match.ingredient(scope, {:name, "Mellanmjölk"})
    refute Repo.get_by(Ingredient, [key: "mellanmjolk"], Tore.Scope.repo_opts(scope))
  end

  test "merging keeps the row already there when both had one" do
    scope = home_scope()
    milk = ingredient(scope, %{name: "Mjölk", category: "dairy"})
    {:ok, _} = tick(scope, "Mjölk")
    {:ok, _} = tick(scope, "Mellanmjölk")

    learned([%{"name" => "Mellanmjölk", "same_as" => "Mjölk", "section" => "dairy"}])

    assert [%{ingredient_id: id}] = Pantry.list_inventory(scope)
    assert id == milk.id
  end

  test "a name that is its own ingredient gets its section and shelf life" do
    scope = home_scope()
    {:ok, _} = tick(scope, "Gräddfil")

    assert %{"learned" => 1} =
             learned([
               %{
                 "name" => "Gräddfil",
                 "same_as" => nil,
                 "section" => "dairy",
                 "shelf_life_days" => 14
               }
             ])

    assert {:ok, %Ingredient{category: "dairy", shelf_life_days: 14}} =
             Match.ingredient(scope, {:name, "Gräddfil"})
  end

  test "a name or a same_as Tore doesn't have is reported, and changes nothing" do
    ingredient(home_scope(), %{name: "Gräddfil"})

    assert %{"unknown_names" => ["Kvarg"], "unknown_same_as" => ["Gräddfil"]} =
             learned([
               %{"name" => "Kvarg", "same_as" => nil, "section" => "dairy"},
               %{"name" => "Gräddfil", "same_as" => "Filmjölk", "section" => "dairy"}
             ])

    assert {:ok, %Ingredient{category: nil}} =
             Match.ingredient(home_scope(), {:name, "Gräddfil"})
  end

  describe "names/2" do
    setup :fake_pi

    test "asks pi about the names not learned yet, as a learn job", %{pi_log: log} do
      ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})

      assert :ok = Learn.names(home_scope(), ["Mjölk", "Gräddfil"])

      prompt = Enum.find(pi_records(log), &(&1["type"] == "prompt"))["message"]
      assert prompt =~ "Background job: learn."
      assert prompt =~ "Names: Gräddfil."
      refute prompt =~ "Names: Mjölk"

      # A name Tore never saw has its ingredient already, as written.
      assert {:ok, %Ingredient{category: nil}} =
               Match.ingredient(home_scope(), {:name, "Gräddfil"})
    end

    test "asks nothing when every name is learned", %{pi_log: log} do
      ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})

      assert :ok = Learn.names(home_scope(), ["Mjölk"])
      refute File.exists?(log)
    end
  end

  test "without pi, a new name stays as written" do
    scope = scope_fixture(household_fixture())
    {:ok, _} = tick(scope, "Gräddfil")

    assert :ok = Learn.names(scope, ["Gräddfil"])
    assert {:ok, %Ingredient{category: nil}} = Match.ingredient(scope, {:name, "Gräddfil"})
  end
end
