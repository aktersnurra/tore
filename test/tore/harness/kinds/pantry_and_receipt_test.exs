defmodule Tore.Harness.Kinds.PantryAndReceiptTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Pantry}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.{CostEntry, PantryBeliefUpdate}
  alias Tore.Harness.Kinds.{PantryUpdate, Receipt}
  alias Tore.Recipes.Ingredient

  setup :verify_on_exit!

  defp names, do: home_scope() |> Pantry.list_inventory() |> Enum.map(& &1.name) |> Enum.sort()

  defp inventory,
    do: home_scope() |> Pantry.list_inventory() |> Enum.map(&Pantry.before_image/1) |> Enum.sort()

  defp tick(items),
    do: Runs.start(home_scope(), PantryUpdate, %{channel: :grocery_checkoff, items: items})

  describe "pantry" do
    test "something seen at home applies straight away, and undo removes what it added" do
      assert {:ok, %KitchenRun{status: :applied, input: input} = run} =
               Runs.start(home_scope(), PantryUpdate, %{
                 channel: :seen,
                 items: [%{name: "mjölk", quantity: 2, unit: "l", category: "dairy"}]
               })

      assert input == %{"channel" => "seen"}
      assert run == Runs.get(home_scope(), run.id)
      assert names() == ["mjölk"]

      {:ok, _} = Runs.revert(home_scope(), run.id)
      assert names() == []
    end

    test "undo puts a row's pack size back" do
      ctx = %{scope: home_scope(), actor: :user}
      Tore.Capture.Dispatch.add_to_pantry("kyckling", 820, "g", ctx, nil, 820)
      bumped = Tore.Capture.Dispatch.add_to_pantry("kyckling", 500, "g", ctx, nil, 500)
      assert [%{pack_size: pack}] = inventory()
      assert Decimal.equal?(pack, 500)

      {:ok, _} = Runs.revert(home_scope(), bumped.run_stream_id)
      assert [%{pack_size: pack}] = inventory()
      assert Decimal.equal?(pack, 820)
    end

    test "undo puts a bumped item back exactly as it was" do
      {:ok, _} = tick([%{name: "smör", quantity: 1, unit: "st"}])
      before = inventory()

      {:ok, run} = tick([%{name: "smör", quantity: 2, unit: "st"}])
      refute inventory() == before

      {:ok, _} = Runs.revert(home_scope(), run.id)
      assert inventory() == before
    end

    test "a ticked name lands on its ingredient, or on one learned for it, asking no model" do
      {:ok, mjolk} =
        %Ingredient{household_id: home_scope().household_id}
        |> Ingredient.changeset(%{name: "Mjölk", key: "mjolk"})
        |> Repo.insert()

      :ok = Tore.Pantry.Match.learn_alias(home_scope(), {:name, "Mellanmjölk"}, mjolk.id)

      assert {:ok, %KitchenRun{status: :applied}} = tick([%{name: "MJÖLK"}])
      assert {:ok, %KitchenRun{status: :applied}} = tick([%{name: "mellanmjölk"}])
      assert [%{ingredient_id: id, name: "mjölk"}] = Pantry.list_inventory(home_scope())
      assert id == mjolk.id
    end

    test "a ticked name Tore doesn't know is kept as written, asking no model" do
      assert {:ok, %KitchenRun{status: :applied}} = tick([%{name: "Gräddfil"}])
      assert names() == ["gräddfil"]
    end

    test "without AI, a ticked item lands on the ingredient with its name, or is kept as written" do
      unsponsored = scope_fixture(household_fixture())

      {:ok, mjolk} =
        %Ingredient{household_id: unsponsored.household_id}
        |> Ingredient.changeset(%{name: "Mjölk", key: "mjolk"})
        |> Repo.insert()

      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.start(unsponsored, PantryUpdate, %{
                 channel: :grocery_checkoff,
                 items: [%{name: "mjölk"}, %{name: "Gräddfil"}]
               })

      rows = Pantry.list_inventory(unsponsored)
      assert Enum.any?(rows, &(&1.ingredient_id == mjolk.id))
      assert "gräddfil" in Enum.map(rows, & &1.name)
    end

    test "a catalogue key the household doesn't have is refused" do
      update = %PantryBeliefUpdate{
        items: [
          %{
            name: "gräddfil",
            change: :added,
            provenance: "manual",
            last_seen_at: DateTime.utc_now(),
            matched_key: "invented_key"
          }
        ]
      }

      assert {:fail, :unknown_ingredient, :reject} =
               PantryUpdate.verify(update, %{scope: home_scope()})
    end

    test "Capture adding by hand asks no model, and undo takes it out" do
      ctx = capture_ctx(home_scope().household_id)

      bubble = Tore.Capture.Dispatch.add_to_pantry("mjölk", 1, "l", ctx)

      assert bubble.text =~ "mjölk"
      assert names() == ["mjölk"]
      {:ok, _} = Runs.revert(home_scope(), bubble.run_stream_id)
      assert names() == []
    end

    test "Capture removing asks no model, and undo puts the row back as it was" do
      {:ok, _} = tick([%{name: "smör", quantity: 2, unit: "st"}])
      before = inventory()
      ctx = capture_ctx(home_scope().household_id)

      bubble = Tore.Capture.Dispatch.remove_from_pantry("smör", ctx)

      assert %KitchenRun{status: :applied, artifacts: [%{items: [%{change: :removed}]}]} =
               Runs.get(home_scope(), bubble.run_stream_id)

      assert names() == []
      {:ok, _} = Runs.revert(home_scope(), bubble.run_stream_id)
      assert inventory() == before
    end

    test "undoing a removal after the item came back leaves one row" do
      {:ok, _} = tick([%{name: "smör", quantity: 2, unit: "st"}])
      ctx = capture_ctx(home_scope().household_id)

      removed = Tore.Capture.Dispatch.remove_from_pantry("smör", ctx)
      {:ok, _} = tick([%{name: "smör", quantity: 1, unit: "st"}])
      {:ok, _} = Runs.revert(home_scope(), removed.run_stream_id)

      assert [%{name: "smör", quantity: quantity}] = inventory()
      assert Decimal.equal?(quantity, 1)
    end

    # Stored before pantry rows knew a pack's size (2026-11-24), an item has no pack_size.
    test "an item stored before pack sizes loads, with none" do
      item = %{
        "name" => "mjölk",
        "change" => "added",
        "quantity" => "1",
        "unit" => "l",
        "category" => nil,
        "expires_on" => nil,
        "provenance" => "manual",
        "last_seen_at" => "2026-11-20T10:00:00Z",
        "catalogue_name" => nil,
        "matched_key" => nil,
        "default_unit" => nil,
        "shelf_life_days" => nil,
        "item_id" => nil
      }

      assert %PantryBeliefUpdate{items: [%{pack_size: nil}]} =
               PantryBeliefUpdate.from_json(%{"items" => [item]})

      with_pack = Map.put(item, "pack_size", "820")

      assert %PantryBeliefUpdate{items: [%{pack_size: pack}]} =
               PantryBeliefUpdate.from_json(%{"items" => [with_pack]})

      assert Decimal.equal?(pack, 820)
    end

    test "a stored item that isn't what an item looks like raises on load" do
      json = %{"items" => [%{"name" => "x"}]}
      assert_raise MatchError, fn -> PantryBeliefUpdate.from_json(json) end
    end
  end

  describe "receipt" do
    # A receipt is logged by someone.
    setup do
      Process.put(:scope, scope_fixture(user_fixture()))
      :ok
    end

    defp member, do: Process.get(:scope)

    # A receipt as pi read it and logged it (log_receipt).
    defp log(store, total, lines \\ []) do
      cost = %CostEntry{
        store_name: store,
        date: ~D[2026-11-04],
        total: Decimal.new(total),
        line_items: lines
      }

      Runs.submit(member(), Receipt, cost, %{actor: :mcp})
    end

    test "applies straight away, and undo deletes the receipt" do
      assert {:ok, %KitchenRun{status: :applied, surface: :shop} = run} =
               log("ICA", "89.5", [%{name: "MJÖLK", quantity: Decimal.new(2)}])

      assert run == Runs.get(member(), run.id)
      assert [%{store_name: "ICA", total_amount: total}] = Costs.recent_receipts(member(), 5)
      assert Decimal.equal?(total, Decimal.new("89.5"))

      {:ok, _} = Runs.revert(member(), run.id)
      assert Costs.recent_receipts(member(), 5) == []
    end

    test "undo still works after the receipt was deleted by hand" do
      {:ok, run} = log("ICA", "10")
      [receipt] = Costs.recent_receipts(member(), 5)
      :ok = Costs.delete_receipt(member(), receipt.id)

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(member(), run.id)
    end

    test "keeps its line items, and leaves the pantry and the shopping list alone" do
      list_id = Tore.Streams.shop_list(member(), ~D[2026-11-02])
      {:ok, _} = Tore.Shop.add_item(member(), list_id, "Mjölk", Decimal.new(1), "l", nil)

      assert {:ok, %KitchenRun{status: :applied}} =
               log("ICA", "89.5", [
                 %{
                   name: "MJÖLK 1.5L",
                   quantity: Decimal.new(2),
                   unit: "st",
                   total_price: Decimal.new("35.8")
                 },
                 %{
                   name: "ÄGG 12P",
                   quantity: Decimal.new(1),
                   unit: "st",
                   total_price: Decimal.new("53.7")
                 }
               ])

      receipt =
        Repo.one!(Tore.Costs.Receipt, Tore.Scope.repo_opts(member())) |> Repo.preload(:line_items)

      assert receipt.line_items |> Enum.map(& &1.product_name) |> Enum.sort() == [
               "MJÖLK 1.5L",
               "ÄGG 12P"
             ]

      milk = Enum.find(receipt.line_items, &(&1.product_name == "MJÖLK 1.5L"))
      assert milk.total_price == Decimal.new("35.8")
      assert milk.unit == "st"

      assert Pantry.list_inventory(member()) == []
      {:ok, %{items: items}} = Tore.Shop.load_list(member(), list_id)
      assert [%{checked: false}] = Map.values(items)
    end

    test "with no store it fails, logging nothing" do
      assert {:ok, %KitchenRun{status: :failed, failure_code: :missing_store}} = log(nil, "10")
      assert Costs.recent_receipts(member(), 5) == []
    end
  end
end
