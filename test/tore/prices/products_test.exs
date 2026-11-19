defmodule Tore.Prices.ProductsTest do
  use Tore.DataCase, async: false

  alias Tore.Pantry.Match
  alias Tore.Prices.{ProductMatch, Products}
  alias Tore.Recipes.Ingredient

  defp ingredient(scope, name) do
    %Ingredient{household_id: scope.household_id}
    |> Ingredient.changeset(%{name: name, category: "other"})
    |> Repo.insert!()
  end

  test "a product with an ingredient's own name matches for free" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")

    assert :ok = Products.match(scope, ["mjölk"])
    assert Products.lookup(scope, ["Mjölk"]) == %{"mjolk" => milk.id}
  end

  describe "with pi" do
    import Tore.FakePi
    setup :fake_pi

    test "the free ones match here, and pi is asked about the rest", %{pi_log: log} do
      scope = home_scope()
      milk = ingredient(scope, "Mjölk")

      assert :ok = Products.match(scope, ["Mjölk", "Mozzarella 21% Riv"])
      assert Products.lookup(scope, ["Mjölk"]) == %{"mjolk" => milk.id}

      prompt = Enum.find(pi_records(log), &(&1["type"] == "prompt"))["message"]
      assert prompt =~ "Background job: learn."
      assert prompt =~ "Products: Mozzarella 21% Riv."
    end

    test "a household with no ingredients asks nobody", %{pi_log: log} do
      assert :ok = Products.match(home_scope(), ["Blåbär"])
      refute File.exists?(log)
    end
  end

  test "a match never reaches the pantry's names" do
    scope = home_scope()
    cheese = ingredient(scope, "Mozzarella")
    :ok = Products.put(scope, "Mozzarella 21% Riv", cheese.id)

    assert Match.ingredient(scope, {:name, "Mozzarella 21% Riv"}) == :unknown
  end

  test "none fits is asked again after four weeks" do
    scope = home_scope()
    ingredient(scope, "Mjölk")
    :ok = Products.put(scope, "Blåbär", nil)
    assert Products.lookup(scope, ["Blåbär"]) == %{"blabar" => nil}

    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -29, :day) |> NaiveDateTime.truncate(:second)
    Repo.update_all(ProductMatch, [set: [updated_at: old]], Tore.Scope.repo_opts(scope))
    assert Products.lookup(scope, ["Blåbär"]) == %{}

    berries = ingredient(scope, "Blåbär")
    assert :ok = Products.match(scope, ["Blåbär"])
    assert Products.lookup(scope, ["Blåbär"]) == %{"blabar" => berries.id}
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
