defmodule Tore.Pantry.LearnTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Pantry
  alias Tore.Pantry.{Learn, Match}
  alias Tore.Recipes.Ingredient

  setup :verify_on_exit!

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

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

  # The canonicaliser's answer for one name, and what it was shown.
  defp answer(norm) do
    test = self()

    expect(Tore.MockLLM, :text, fn system, user, _opts ->
      send(test, {:asked, system <> user})

      {:ok,
       %{
         "items" => [
           Map.merge(
             %{"category" => "other", "default_unit" => nil, "matched_key" => nil},
             norm
           )
         ]
       }, @usage}
    end)
  end

  test "a new name that means an ingredient Tore has is merged into it, once" do
    scope = home_scope()
    milk = ingredient(scope, %{name: "Mjölk", category: "dairy"})
    {:ok, _} = tick(scope, "Mellanmjölk")

    answer(%{
      "raw_name" => "Mellanmjölk",
      "catalogue_name" => "Mjölk",
      "matched_key" => "mjolk",
      "category" => "dairy"
    })

    assert :ok = Learn.name(scope, "Mellanmjölk")
    assert_received {:asked, user}
    assert user =~ "mjolk  (Mjölk)"
    refute user =~ "mellanmjolk  ("

    assert [%{ingredient_id: id, name: "mjölk"}] = Pantry.list_inventory(scope)
    assert id == milk.id
    assert {:ok, %Ingredient{id: ^id}} = Match.ingredient(scope, {:name, "Mellanmjölk"})
    refute Repo.get_by(Ingredient, [key: "mellanmjolk"], Tore.Scope.repo_opts(scope))

    # Learned: the same name again asks nothing.
    assert :ok = Learn.name(scope, "Mellanmjölk")
  end

  test "merging keeps the row already there when both had one" do
    scope = home_scope()
    milk = ingredient(scope, %{name: "Mjölk", category: "dairy"})
    {:ok, _} = tick(scope, "Mjölk")
    {:ok, _} = tick(scope, "Mellanmjölk")

    answer(%{"raw_name" => "Mellanmjölk", "catalogue_name" => "Mjölk", "matched_key" => "mjolk"})
    assert :ok = Learn.name(scope, "Mellanmjölk")

    assert [%{ingredient_id: id}] = Pantry.list_inventory(scope)
    assert id == milk.id
  end

  test "a new name that is its own ingredient gets its section and shelf life" do
    scope = home_scope()
    {:ok, _} = tick(scope, "Gräddfil")

    answer(%{
      "raw_name" => "Gräddfil",
      "catalogue_name" => "Gräddfil",
      "category" => "dairy",
      "shelf_life_days" => 14
    })

    assert :ok = Learn.name(scope, "Gräddfil")

    assert {:ok, %Ingredient{category: "dairy", shelf_life_days: 14}} =
             Match.ingredient(scope, {:name, "Gräddfil"})
  end

  test "a name already learned, or unknown, asks nothing" do
    scope = home_scope()
    ingredient(scope, %{name: "Mjölk", category: "dairy"})

    assert :ok = Learn.name(scope, "Mjölk")
    assert :ok = Learn.name(scope, "Finns inte")
  end

  test "without the model, nothing is asked and the name stays as written" do
    scope = scope_fixture(household_fixture())
    {:ok, _} = tick(scope, "Gräddfil")

    assert :ok = Learn.name(scope, "Gräddfil")
    assert {:ok, %Ingredient{category: nil}} = Match.ingredient(scope, {:name, "Gräddfil"})
  end

  test "a section the model invents is kept as other" do
    scope = home_scope()
    {:ok, _} = tick(scope, "Gräddfil")
    answer(%{"raw_name" => "Gräddfil", "catalogue_name" => "Gräddfil", "category" => "mejeri"})

    assert :ok = Learn.name(scope, "Gräddfil")
    assert {:ok, %Ingredient{category: "other"}} = Match.ingredient(scope, {:name, "Gräddfil"})
  end
end
