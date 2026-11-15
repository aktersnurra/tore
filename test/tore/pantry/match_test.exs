defmodule Tore.Pantry.MatchTest do
  use Tore.DataCase, async: false

  alias Tore.Pantry.Match
  alias Tore.Recipes.Ingredient

  defp ingredient(scope, name) do
    %Ingredient{household_id: scope.household_id}
    |> Ingredient.changeset(%{name: name})
    |> Repo.insert!()
  end

  test "a name finds the ingredient with the same key" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")

    assert {:ok, %Ingredient{id: id}} = Match.ingredient(scope, {:name, "mjölk"})
    assert id == milk.id
    assert {:ok, %Ingredient{id: ^id}} = Match.ingredient(scope, {:name, "  MJÖLK "})
  end

  test "a learned name finds its ingredient" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")
    :ok = Match.learn_alias(scope, {:name, "Mellanmjölk"}, milk.id)

    assert {:ok, %Ingredient{id: id}} = Match.ingredient(scope, {:name, "mellanmjölk"})
    assert id == milk.id
  end

  test "a learned barcode finds its ingredient, and only as a barcode" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")
    :ok = Match.learn_alias(scope, {:barcode, "7310865004703"}, milk.id)

    assert {:ok, %Ingredient{id: id}} = Match.ingredient(scope, {:barcode, "7310865004703"})
    assert id == milk.id
    assert Match.ingredient(scope, {:name, "7310865004703"}) == :unknown
  end

  test "learning the same alias twice keeps the first" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")
    cream = ingredient(scope, "Grädde")
    :ok = Match.learn_alias(scope, {:name, "Mellanmjölk"}, milk.id)
    :ok = Match.learn_alias(scope, {:name, "Mellanmjölk"}, cream.id)

    assert {:ok, %Ingredient{id: id}} = Match.ingredient(scope, {:name, "Mellanmjölk"})
    assert id == milk.id
  end

  test "nothing matches a part of a name" do
    scope = home_scope()
    ingredient(scope, "Mjölk")

    assert Match.ingredient(scope, {:name, "mjölkchoklad"}) == :unknown
    assert Match.ingredient(scope, {:name, "mjöl"}) == :unknown
    assert Match.ingredient(scope, {:name, ""}) == :unknown
  end

  test "another household's ingredients and aliases never match" do
    scope = home_scope()
    other = Tore.AccountsFixtures.household_fixture() |> Tore.AccountsFixtures.scope_fixture()
    theirs = ingredient(other, "Mjölk")
    :ok = Match.learn_alias(other, {:barcode, "7310865004703"}, theirs.id)

    assert Match.ingredient(scope, {:name, "Mjölk"}) == :unknown
    assert Match.ingredient(scope, {:barcode, "7310865004703"}) == :unknown
  end

  test "an ingredient's category is one of the shop's sections" do
    scope = home_scope()

    assert %{valid?: true} =
             Ingredient.changeset(%Ingredient{household_id: scope.household_id}, %{
               name: "Lax",
               category: "fish"
             })

    assert %{valid?: false, errors: [category: _]} =
             Ingredient.changeset(%Ingredient{household_id: scope.household_id}, %{
               name: "Lax",
               category: "seafood"
             })
  end
end
