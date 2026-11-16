defmodule Tore.PricesTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Deals, Prices, Recipes}
  alias Tore.Prices.{Estimate, Products, Units}
  alias Tore.Recipes.Ingredient

  setup :verify_on_exit!

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}
  @week ~D[2026-11-16]

  setup do
    scope = home_scope()
    store = Repo.insert!(%Tore.Deals.Store{name: "ICA Maxi", url: "https://example.test/maxi"})
    Repo.insert!(%Tore.Deals.HouseholdStore{household_id: scope.household_id, store_id: store.id})
    %{scope: scope}
  end

  defp d(s), do: Decimal.new(s)

  defp recipe(scope, servings, ingredients) do
    {:ok, recipe} =
      Recipes.create(
        scope,
        %{
          title: "Kyckling",
          recipe_type: :meal,
          base_servings: servings,
          ingredients: ingredients
        },
        image: false
      )

    recipe
  end

  defp ingredient_id(scope, name),
    do: Repo.get_by!(Ingredient, [name: name], Tore.Scope.repo_opts(scope)).id

  defp deal(attrs) do
    Deals.upsert_deals([Map.merge(%{chain: "ica", store: "ICA Maxi", quantity: 1}, attrs)])
  end

  defp paid(scope, date, lines) do
    {:ok, _} =
      Tore.Costs.log_receipt(scope, %{
        date: date,
        store_name: "ICA",
        total_amount: d("100"),
        user_id: user_fixture().id,
        line_items: lines
      })
  end

  describe "units" do
    test "weights and volumes convert within themselves" do
      assert Units.to_base(d("400"), "g") == {d("0.400"), "kg"}
      assert Units.to_base(d("2"), "dl") == {d("0.2"), "l"}
      assert Units.to_base(d("1"), "msk") == {d("0.015"), "l"}
      assert Units.to_base(d("3"), nil) == {d("3"), "st"}
      assert Units.to_base(d("3"), "St.") == {d("3"), "st"}
      assert Units.to_base(d("1"), "nypa") == :unknown
    end
  end

  describe "a line's cost" do
    defp sources do
      %{
        deal: %{"kg" => d("100")},
        paid: %{"kg" => d("120"), "st" => d("60")},
        regular: %{"kg" => d("150")},
        estimate: %{"l" => d("20")}
      }
    end

    test "the first source with a price in the line's unit wins" do
      line = %{ingredient_id: 1, quantity: d("400"), unit: "g"}
      assert Prices.line_cost(line, sources()) == {:deal, d("40.000")}

      assert Prices.line_cost(%{line | unit: "st", quantity: d("2")}, sources()) ==
               {:paid, d("120")}

      assert Prices.line_cost(%{line | unit: "dl", quantity: d("5")}, sources()) ==
               {:estimate, d("10.0")}
    end

    test "no quantity, or no price in the unit, is unpriced" do
      assert Prices.line_cost(%{ingredient_id: 1, quantity: nil, unit: "g"}, sources()) ==
               :unpriced

      assert Prices.line_cost(%{ingredient_id: 1, quantity: d("1"), unit: "nypa"}, sources()) ==
               :unpriced

      assert Prices.line_cost(%{ingredient_id: 1, quantity: d("1"), unit: "g"}, %{}) == :unpriced
    end

    test "an estimate adds to the amount but doesn't count as priced" do
      lines = [
        %{ingredient_id: 1, quantity: d("1"), unit: "kg"},
        %{ingredient_id: 2, quantity: d("1"), unit: "l"},
        %{ingredient_id: 3, quantity: nil, unit: nil}
      ]

      prices = %{1 => %{deal: %{"kg" => d("50")}}, 2 => %{estimate: %{"l" => d("15")}}}

      assert Prices.cost(lines, prices) == %{amount: d("65.00"), priced: 1, total: 3}
    end
  end

  describe "recipe costs" do
    test "a deal running in the week, per kg from its comparison price", %{scope: scope} do
      r = recipe(scope, 4, [%{name: "Kycklingfilé", quantity: 500, unit: "g"}])
      Products.put(scope, "Kycklingfilé Kronfågel", ingredient_id(scope, "Kycklingfilé"))

      deal(%{
        product_name: "Kycklingfilé Kronfågel",
        price: d("59"),
        price_unit: "st",
        comparison_price: d("118"),
        comparison_unit: "kg",
        valid_until: Date.add(@week, 6)
      })

      assert Prices.recipe_costs(scope, [{r, 4}], @week) == %{
               r.id => %{amount: d("59.00"), priced: 1, total: 1}
             }

      # Twice the servings, twice the chicken.
      assert %{amount: amount} = Prices.recipe_costs(scope, [{r, 8}], @week)[r.id]
      assert amount == d("118.00")
    end

    test "a multi-buy is priced per item", %{scope: scope} do
      r = recipe(scope, 2, [%{name: "Glass", quantity: 1, unit: "st"}])
      Products.put(scope, "Gräddglass", ingredient_id(scope, "Glass"))

      deal(%{
        product_name: "Gräddglass",
        price: d("40"),
        quantity: 3,
        price_unit: "st",
        valid_until: Date.add(@week, 6)
      })

      assert %{amount: amount, priced: 1} = Prices.recipe_costs(scope, [{r, 2}], @week)[r.id]
      assert amount == d("13.33")
    end

    test "a deal that ends before the week gives only its regular price", %{scope: scope} do
      r = recipe(scope, 2, [%{name: "Mjölk", quantity: 1, unit: "l"}])
      Products.put(scope, "Mellanmjölk", ingredient_id(scope, "Mjölk"))

      deal(%{
        product_name: "Mellanmjölk",
        price: d("10"),
        price_unit: "l",
        regular_price: d("16.90"),
        valid_until: Date.add(@week, -1)
      })

      assert %{amount: amount, priced: 1} = Prices.recipe_costs(scope, [{r, 2}], @week)[r.id]
      assert amount == d("16.90")
    end

    test "the latest price paid comes before a regular price", %{scope: scope} do
      r = recipe(scope, 2, [%{name: "Lax", quantity: 300, unit: "g"}])
      salmon = ingredient_id(scope, "Lax")
      Products.put(scope, "LAXFILE", salmon)
      Products.put(scope, "Laxfilé", salmon)

      deal(%{
        product_name: "Laxfilé",
        price: d("149"),
        price_unit: "kg",
        regular_price: d("249"),
        valid_until: Date.add(@week, -10)
      })

      paid(scope, ~D[2026-10-01], [
        %{product_name: "LAXFILE", quantity: d("0.5"), unit: "kg", total_price: d("90")}
      ])

      paid(scope, ~D[2026-11-10], [
        %{product_name: "LAXFILE", quantity: d("0.4"), unit: "kg", total_price: d("80")}
      ])

      # 200 kr/kg from the latest receipt, for 0.3 kg.
      assert %{amount: amount} = Prices.recipe_costs(scope, [{r, 2}], @week)[r.id]
      assert amount == d("60.00")
    end

    test "with nothing known, the estimate prices it unpriced", %{scope: scope} do
      r = recipe(scope, 2, [%{name: "Lök", quantity: 2, unit: "st"}, %{name: "Salt"}])

      Repo.update_all(
        Ingredient,
        [set: [estimated_price: d("4"), estimated_unit: "st"]],
        Tore.Scope.repo_opts(scope)
      )

      assert Prices.recipe_costs(scope, [{r, 2}], @week)[r.id] ==
               %{amount: d("8.00"), priced: 0, total: 2}
    end
  end

  describe "estimates" do
    test "one call guesses what nothing prices, and only fitting answers are kept", %{
      scope: scope
    } do
      recipe(scope, 2, [%{name: "Lök", quantity: 2}, %{name: "Grädde", quantity: 2, unit: "dl"}])

      expect(Tore.MockLLM, :text, fn _system, user, _opts ->
        assert user =~ "Lök"
        assert user =~ "Grädde"

        {:ok,
         %{
           "items" => [
             %{"name" => "Lök", "price" => 4.5, "unit" => "st"},
             %{"name" => "Grädde", "price" => 45, "unit" => "dl"}
           ]
         }, @usage}
      end)

      assert :ok = Estimate.missing(scope)

      onion = Repo.get_by!(Ingredient, [name: "Lök"], Tore.Scope.repo_opts(scope))
      assert Decimal.eq?(onion.estimated_price, d("4.5"))
      assert onion.estimated_unit == "st"

      assert Repo.get_by!(Ingredient, [name: "Grädde"], Tore.Scope.repo_opts(scope)).estimated_price ==
               nil
    end

    test "nothing to guess asks no model", %{scope: scope} do
      # No MockLLM expectation: a model call fails the test.
      assert :ok = Estimate.missing(scope)
    end
  end
end
