defmodule Tore.Harness.UndoTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.Undo

  @slot %{
    recipe_id: 7,
    servings: 4,
    skipped: false,
    leftover: true,
    reason: nil,
    place: nil,
    amount: nil
  }
  @eating_out %{
    recipe_id: nil,
    servings: nil,
    skipped: true,
    leftover: false,
    reason: "eating_out",
    place: "Sushibaren",
    amount: "450.5"
  }

  @pantry %{
    name: "Mjölk",
    ingredient_id: 12,
    quantity: Decimal.new("1.5"),
    unit: "l",
    category: "dairy",
    added_at: ~D[2026-11-01],
    expires_at: ~D[2026-11-08],
    expires_source: "estimated",
    provenance: "receipt",
    belief: "confirmed",
    last_seen_at: ~U[2026-11-02 08:00:00Z]
  }

  defp round_trip(undo),
    do: undo |> Undo.encode() |> Jason.encode!() |> Jason.decode!() |> Undo.decode()

  test "every shape survives JSON unchanged" do
    for undo <- [
          {:irreversible, "no before-image"},
          {:steps, []},
          {:steps,
           [
             {:restore_plan_slots, "plan-1-2026-11-09",
              %{
                "mon_dinner" => %{slot: @slot, pin: true},
                "tue_dinner" => %{slot: :empty, pin: :none},
                "wed_dinner" => %{slot: @eating_out, pin: %{"recipe_id" => 3}}
              }},
             {:restore_pantry_item, 4, @pantry},
             {:restore_pantry_item, 5, :absent},
             {:restore_memory, [1, 2], [3]},
             {:delete_receipt, 9},
             {:delete_recipe, 10},
             {:remove_shop_item, "shop-1-2026-11-09", "9b2c"},
             {:uncheck_shop_item, "shop-1-2026-11-09", "9b2c"}
           ]}
        ] do
      assert round_trip(undo) == undo
    end
  end

  test "a pantry before-image keeps its types" do
    {:steps, [{:restore_pantry_item, 4, before}]} =
      round_trip({:steps, [{:restore_pantry_item, 4, @pantry}]})

    assert %Decimal{} = before.quantity
    assert %Date{} = before.expires_at
    assert %DateTime{} = before.last_seen_at
  end

  test "an unknown shape raises instead of becoming an undo that does nothing" do
    assert_raise ArgumentError, fn -> Undo.decode(%{"snapshot" => %{}}) end
    assert_raise ArgumentError, fn -> Undo.decode(%{"steps" => [%{"restore_shop" => 1}]}) end
    assert_raise ArgumentError, fn -> Undo.encode({:steps, [{:restore_shop, 1}]}) end

    assert_raise ArgumentError, fn ->
      Undo.decode(%{
        "steps" => [
          %{
            "restore_plan_slots" => %{
              "plan_id" => "p",
              "slots" => %{"mon_dinner" => %{"slot" => %{"skipped" => "no"}}}
            }
          }
        ]
      })
    end
  end

  test "a key nothing reads is refused rather than dropped" do
    for json <- [
          %{"steps" => [%{"delete_receipt" => 1, "delete_recipe" => 2}]},
          %{"irreversible" => "x", "steps" => []},
          %{
            "steps" => [
              %{
                "restore_plan_slots" => %{
                  "plan_id" => "p",
                  "slots" => %{
                    "mon_dinner" => %{"slot" => %{"skipped" => false, "leftover" => false}}
                  }
                }
              }
            ]
          },
          %{
            "steps" => [
              %{"restore_memory" => %{"added_ids" => [1], "forgotten_ids" => [], "extra" => 1}}
            ]
          }
        ] do
      assert_raise ArgumentError, fn -> Undo.decode(json) end
    end
  end

  test "a pantry before-image needs every field, so a restore can't blank one" do
    assert_raise KeyError, fn ->
      Undo.encode({:steps, [{:restore_pantry_item, 1, %{name: "Mjölk"}}]})
    end

    assert_raise ArgumentError, fn ->
      Undo.encode({:steps, [{:restore_pantry_item, 1, Map.put(@pantry, :colour, "white")}]})
    end
  end

  test "only the irreversible shape refuses" do
    refute Undo.reversible?({:irreversible, "x"})
    assert Undo.reversible?({:steps, []})
  end
end
