defmodule Tore.Pantry.OpenFoodFactsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Tore.Pantry.OpenFoodFacts

  setup :verify_on_exit!

  defp found(product), do: {:ok, %{"status" => 1, "product" => product}}

  test "a known product gives its Swedish name and its pack" do
    expect(Tore.MockHTTP, :fetch, fn url ->
      assert url =~ "/api/v2/product/7310865004703"

      found(%{
        "product_name_sv" => "Mellanmjölk",
        "product_name" => "Milk",
        "quantity" => "1,5 l"
      })
    end)

    assert OpenFoodFacts.product("7310865004703") ==
             {:ok, %{name: "Mellanmjölk", quantity: Decimal.new("1.5"), unit: "l"}}
  end

  test "the plain name serves when there's no Swedish one, and a pack it can't read is left out" do
    expect(Tore.MockHTTP, :fetch, fn _ ->
      found(%{"product_name" => "Havregryn", "quantity" => "a big bag"})
    end)

    assert OpenFoodFacts.product("7310130007019") ==
             {:ok, %{name: "Havregryn", quantity: nil, unit: nil}}
  end

  test "a pack of several is counted up" do
    expect(Tore.MockHTTP, :fetch, fn _ ->
      found(%{"product_name" => "Pilsner", "quantity" => "6 x 33 cl"})
    end)

    assert {:ok, %{quantity: q, unit: "cl"}} = OpenFoodFacts.product("7310070765823")
    assert Decimal.equal?(q, 198)
  end

  test "units are read in any case and with no space" do
    expect(Tore.MockHTTP, :fetch, fn _ ->
      found(%{"product_name" => "Mjöl", "quantity" => "2KG"})
    end)

    assert {:ok, %{quantity: q, unit: "kg"}} = OpenFoodFacts.product("7310130000010")
    assert Decimal.equal?(q, 2)
  end

  test "a code nobody knows, or a product with no name, is unknown" do
    expect(Tore.MockHTTP, :fetch, fn _ -> {:error, {:http_error, 404}} end)
    assert OpenFoodFacts.product("4000000000000") == :unknown

    expect(Tore.MockHTTP, :fetch, fn _ -> {:ok, %{"status" => 0}} end)
    assert OpenFoodFacts.product("4000000000000") == :unknown

    expect(Tore.MockHTTP, :fetch, fn _ -> found(%{"product_name" => ""}) end)
    assert OpenFoodFacts.product("4000000000000") == :unknown
  end

  test "a failed request is an error, not unknown" do
    expect(Tore.MockHTTP, :fetch, fn _ -> {:error, {:req_error, :timeout}} end)
    assert {:error, _} = OpenFoodFacts.product("7310865004703")
  end
end
