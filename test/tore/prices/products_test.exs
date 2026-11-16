defmodule Tore.Prices.ProductsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Pantry.Match
  alias Tore.Prices.{ProductMatch, Products}
  alias Tore.Recipes.Ingredient

  setup :verify_on_exit!

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  defp ingredient(scope, name) do
    %Ingredient{household_id: scope.household_id}
    |> Ingredient.changeset(%{name: name, category: "other"})
    |> Repo.insert!()
  end

  # The canonicaliser's answer: raw name => matched key.
  defp answer(matches) do
    expect(Tore.MockLLM, :text, fn _system, _user, _opts ->
      items =
        for {raw, key} <- matches do
          %{
            "raw_name" => raw,
            "catalogue_name" => raw,
            "category" => "other",
            "default_unit" => nil,
            "matched_key" => key,
            "shelf_life_days" => nil
          }
        end

      {:ok, %{"items" => items}, @usage}
    end)
  end

  test "a product with an ingredient's own name matches without the model" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")

    assert :ok = Products.match(scope, ["mjölk"])
    assert Products.lookup(scope, ["Mjölk"]) == %{"mjolk" => milk.id}
  end

  test "the model matches new products once, and only to the household's own ingredients" do
    scope = home_scope()
    cheese = ingredient(scope, "Mozzarella")

    answer([
      {"Mozzarella 21% Riv", "mozzarella"},
      {"Stora blåbär i ask", nil},
      {"Kräftstjärtar", "krafta"}
    ])

    assert :ok =
             Products.match(scope, ["Mozzarella 21% Riv", "Stora blåbär i ask", "Kräftstjärtar"])

    assert Products.lookup(scope, ["Mozzarella 21% Riv", "Stora blåbär i ask", "Kräftstjärtar"]) ==
             %{
               "mozzarella_21_riv" => cheese.id,
               "stora_blabar_i_ask" => nil,
               "kraftstjartar" => nil
             }

    # Matched or not, a product isn't asked about again.
    assert :ok = Products.match(scope, ["Mozzarella 21% Riv", "Stora blåbär i ask"])
  end

  test "a match never reaches the pantry's names" do
    scope = home_scope()
    ingredient(scope, "Mozzarella")
    answer([{"Mozzarella 21% Riv", "mozzarella"}])

    Products.match(scope, ["Mozzarella 21% Riv"])

    assert Match.ingredient(scope, {:name, "Mozzarella 21% Riv"}) == :unknown
  end

  test "none fits is asked again after four weeks" do
    scope = home_scope()
    ingredient(scope, "Mjölk")
    answer([{"Blåbär", nil}])
    Products.match(scope, ["Blåbär"])

    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -29, :day) |> NaiveDateTime.truncate(:second)
    Repo.update_all(ProductMatch, [set: [updated_at: old]], Tore.Scope.repo_opts(scope))
    assert Products.lookup(scope, ["Blåbär"]) == %{}

    berries = ingredient(scope, "Blåbär")
    assert :ok = Products.match(scope, ["Blåbär"])
    assert Products.lookup(scope, ["Blåbär"]) == %{"blabar" => berries.id}
  end

  test "a household with no ingredients asks no model" do
    # No MockLLM expectation: a model call fails the test.
    assert :ok = Products.match(home_scope(), ["Blåbär"])
    assert Products.lookup(home_scope(), ["Blåbär"]) == %{}
  end

  test "without the model only free matches are made" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")

    # No MockLLM expectation: a model call fails the test.
    assert :ok = Products.match(scope, ["Mjölk", "Gräddglass, Sorbet"], model: false)
    assert Products.lookup(scope, ["Mjölk", "Gräddglass, Sorbet"]) == %{"mjolk" => milk.id}
  end

  test "put takes only the household's own ingredients" do
    scope = home_scope()
    other = scope_fixture(household_fixture())
    theirs = ingredient(other, "Ost")
    ours = ingredient(scope, "Ost")

    assert {:error, :unknown_ingredient} = Products.put(scope, "Präst 31%", theirs.id)
    assert :ok = Products.put(scope, "Präst 31%", ours.id)
    assert :ok = Products.put(scope, "Glass", nil)

    assert Products.lookup(scope, ["Präst 31%", "Glass"]) ==
             %{"prast_31" => ours.id, "glass" => nil}

    assert Products.lookup(other, ["Präst 31%"]) == %{}
  end
end
