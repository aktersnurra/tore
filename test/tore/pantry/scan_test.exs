defmodule Tore.Pantry.ScanTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Pantry, Shop}
  alias Tore.Harness.Runs
  alias Tore.Pantry.{Match, Scan}
  alias Tore.Recipes.Ingredient

  setup :verify_on_exit!

  @milk "7310865004703"

  defp list_id(scope \\ home_scope()), do: Tore.Streams.shop_list(scope, ~D[2026-11-16])

  defp ingredient(scope, name) do
    %Ingredient{household_id: scope.household_id}
    |> Ingredient.changeset(%{name: name, category: "dairy"})
    |> Repo.insert!()
  end

  defp open_food_facts(product) do
    expect(Tore.MockHTTP, :fetch, fn url ->
      assert url =~ @milk
      {:ok, %{"status" => 1, "product" => product}}
    end)
  end

  defp pantry(scope \\ home_scope()) do
    scope
    |> Pantry.list_inventory()
    |> Enum.map(&{&1.name, &1.quantity && Decimal.to_string(&1.quantity, :normal), &1.unit})
  end

  test "a code Tore has never seen is looked up once, and goes into the pantry as the product" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")
    open_food_facts(%{"product_name_sv" => "Arla Mellanmjölk 1,5 %", "quantity" => "1 l"})

    assert {:ok, %{name: "Arla Mellanmjölk 1,5 %", change: :added, run_id: run_id}} =
             Scan.scan(scope, list_id(), @milk, user_id: nil)

    assert pantry() == [{"arla mellanmjölk 1,5 %", "1", "l"}]
    assert %{provenance: "barcode"} = hd(Pantry.list_inventory(scope))

    # pi learns afterwards that it's milk: the pantry row and the code follow.
    assert :merged =
             Tore.Pantry.Learn.learn(scope, %{
               name: "Arla Mellanmjölk 1,5 %",
               same_as: "Mjölk",
               section: "dairy",
               shelf_life_days: nil
             })

    assert pantry() == [{"mjölk", "1", "l"}]
    assert {:ok, %Ingredient{id: id}} = Match.ingredient(scope, {:barcode, @milk})
    assert id == milk.id

    # The second pack asks nobody, and adds its pack.
    assert {:ok, %{name: "Mjölk", change: :added}} =
             Scan.scan(scope, list_id(), @milk, user_id: nil)

    assert pantry() == [{"mjölk", "2", "l"}]

    {:ok, _} = Runs.revert(scope, run_id)
  end

  test "without pi, the product's name is kept as written" do
    scope = scope_fixture(household_fixture())
    open_food_facts(%{"product_name" => "Mellanmjölk", "quantity" => "1 l"})

    assert {:ok, %{name: "Mellanmjölk", change: :added}} =
             Scan.scan(scope, list_id(scope), @milk, user_id: nil)

    assert pantry(scope) == [{"mellanmjölk", "1", "l"}]
  end

  test "a code nobody knows asks for a name once, then is known" do
    scope = home_scope()
    expect(Tore.MockHTTP, :fetch, fn _ -> {:error, {:http_error, 404}} end)

    assert Scan.scan(scope, list_id(), @milk, user_id: nil) == {:error, :unknown_product}

    ingredient(scope, "Mjölk")

    assert {:ok, %{name: "Mjölk", change: :added}} =
             Scan.scan(scope, list_id(), @milk, user_id: nil, name: "mjölk")

    assert {:ok, %{name: "Mjölk"}} = Scan.scan(scope, list_id(), @milk, user_id: nil)
    assert pantry() == [{"mjölk", nil, nil}]
  end

  test "a pack still on the list is ticked off instead" do
    scope = home_scope()
    milk = ingredient(scope, "Mjölk")
    :ok = Match.learn_alias(scope, {:barcode, @milk}, milk.id)
    {:ok, _} = Shop.add_item(scope, list_id(), "mjölk", Decimal.new(1), "l", nil)
    {:ok, _} = Shop.add_item(scope, list_id(), "Bröd", nil, nil, nil)

    assert {:ok, %{name: "mjölk", change: :ticked, item_id: item_id}} =
             Scan.scan(scope, list_id(), @milk, user_id: nil)

    {:ok, state} = Shop.load_list(scope, list_id())
    assert %{checked: true} = state.items[item_id]
    assert pantry() == [{"mjölk", "1", "l"}]
  end

  test "anything but a shop barcode is refused" do
    assert Scan.scan(home_scope(), list_id(), "https://example.com", user_id: nil) ==
             {:error, :not_a_barcode}

    assert Scan.scan(home_scope(), list_id(), "12345", user_id: nil) == {:error, :not_a_barcode}
  end

  test "a failed lookup changes nothing" do
    expect(Tore.MockHTTP, :fetch, fn _ -> {:error, {:req_error, :timeout}} end)

    assert {:error, {:lookup_failed, _}} = Scan.scan(home_scope(), list_id(), @milk, user_id: nil)
    assert pantry() == []
  end
end
