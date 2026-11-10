defmodule Tore.Harness.Kinds.PantryAndReceiptTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Pantry}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.{CostEntry, PantryBeliefUpdate}
  alias Tore.Harness.Kinds.{PantryUpdate, Receipt}
  alias Tore.Recipes.Ingredient

  setup :verify_on_exit!

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  defp names, do: home_scope() |> Pantry.list_inventory() |> Enum.map(& &1.name) |> Enum.sort()

  defp inventory,
    do: home_scope() |> Pantry.list_inventory() |> Enum.map(&Pantry.before_image/1) |> Enum.sort()

  # The canonicaliser's answer: each raw name to `matches[name]`, or to itself.
  defp canonicalise(raw, matches \\ %{}) do
    expect(Tore.MockLLM, :text, fn _system, _user, _opts ->
      norm =
        for name <- raw do
          {catalogue, key} = Map.get(matches, name, {name, nil})

          %{
            "raw_name" => name,
            "catalogue_name" => catalogue,
            "category" => "other",
            "default_unit" => nil,
            "matched_key" => key
          }
        end

      {:ok, %{"items" => norm}, @usage}
    end)
  end

  defp tick(items),
    do: Runs.start(home_scope(), PantryUpdate, %{channel: :grocery_checkoff, items: items})

  describe "pantry" do
    test "a shelf photo applies straight away, and undo removes what it added" do
      expect(Tore.MockLLM, :vision, fn _, _, _, _ ->
        {:ok,
         %{
           "items" => [
             %{"name" => "mjölk", "quantity" => 2, "unit" => "l", "category" => "dairy"}
           ]
         }, @usage}
      end)

      canonicalise(["mjölk"])

      assert {:ok, %KitchenRun{status: :applied, input: input} = run} =
               Runs.start(home_scope(), PantryUpdate, %{
                 channel: :shelf_photo,
                 image_binary: <<1, 2>>
               })

      assert input == %{"channel" => "shelf_photo"}
      assert run == Runs.get(home_scope(), run.id)
      assert names() == ["mjölk"]

      {:ok, _} = Runs.revert(home_scope(), run.id)
      assert names() == []
    end

    test "undo puts a bumped item back exactly as it was" do
      canonicalise(["smör"])
      {:ok, _} = tick([%{name: "smör", quantity: 1, unit: "st"}])
      before = inventory()

      canonicalise(["smör"])
      {:ok, run} = tick([%{name: "smör", quantity: 2, unit: "st"}])
      refute inventory() == before

      {:ok, _} = Runs.revert(home_scope(), run.id)
      assert inventory() == before
    end

    test "a name matched to a catalogue ingredient the household has lands on it" do
      {:ok, mjolk} =
        %Ingredient{household_id: home_scope().household_id}
        |> Ingredient.changeset(%{name: "Mjölk", key: "mjolk"})
        |> Repo.insert()

      canonicalise(["MJÖLK 1.5L"], %{"MJÖLK 1.5L" => {"Mjölk", "mjolk"}})

      assert {:ok, %KitchenRun{status: :applied}} = tick([%{name: "MJÖLK 1.5L"}])
      assert [%{ingredient_id: id}] = Pantry.list_inventory(home_scope())
      assert id == mjolk.id
    end

    test "an invented catalogue key fails the run and creates no ingredient" do
      canonicalise(["gräddfil"], %{"gräddfil" => {"Gräddfil", "invented_key"}})

      assert {:ok, %KitchenRun{status: :failed, failure_code: :unknown_ingredient}} =
               tick([%{name: "gräddfil"}])

      assert names() == []
      refute Repo.get_by(Ingredient, [key: "invented_key"], Tore.Scope.repo_opts(home_scope()))
    end

    test "a shelf photo with nothing on it applies without asking the canonicaliser" do
      expect(Tore.MockLLM, :vision, fn _, _, _, _ -> {:ok, %{"items" => []}, @usage} end)

      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.start(home_scope(), PantryUpdate, %{
                 channel: :shelf_photo,
                 image_binary: <<1>>
               })
    end

    test "Capture adding by hand asks no model, and undo takes it out" do
      ctx = %{household_id: home_scope().household_id, user_id: nil}

      bubble = Tore.Capture.Dispatch.add_to_pantry("mjölk", 1, "l", ctx)

      assert bubble.text =~ "mjölk"
      assert names() == ["mjölk"]
      {:ok, _} = Runs.revert(home_scope(), bubble.run_stream_id)
      assert names() == []
    end

    test "Capture removing asks no model, and undo puts the row back as it was" do
      canonicalise(["smör"])
      {:ok, _} = tick([%{name: "smör", quantity: 2, unit: "st"}])
      before = inventory()
      ctx = %{household_id: home_scope().household_id, user_id: nil}

      bubble = Tore.Capture.Dispatch.remove_from_pantry("smör", ctx)

      assert %KitchenRun{status: :applied, artifacts: [%{items: [%{change: :removed}]}]} =
               Runs.get(home_scope(), bubble.run_stream_id)

      assert names() == []
      {:ok, _} = Runs.revert(home_scope(), bubble.run_stream_id)
      assert inventory() == before
    end

    test "undoing a removal after the item came back leaves one row" do
      canonicalise(["smör"])
      {:ok, _} = tick([%{name: "smör", quantity: 2, unit: "st"}])
      ctx = %{household_id: home_scope().household_id, user_id: nil}

      removed = Tore.Capture.Dispatch.remove_from_pantry("smör", ctx)
      canonicalise(["smör"])
      {:ok, _} = tick([%{name: "smör", quantity: 1, unit: "st"}])
      {:ok, _} = Runs.revert(home_scope(), removed.run_stream_id)

      assert [%{name: "smör", quantity: quantity}] = inventory()
      assert Decimal.equal?(quantity, 1)
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

    defp read(receipt) do
      expect(Tore.MockLLM, :vision, fn _, _, _, _ -> {:ok, receipt, @usage} end)
    end

    defp start, do: Runs.start(member(), Receipt, %{image_binary: <<1>>, image_path: nil})

    test "applies straight away, and undo deletes the receipt" do
      read(%{
        "total" => 89.5,
        "store_name" => "ICA",
        "purchase_date" => "2026-11-04",
        "items" => [%{"name" => "MJÖLK", "quantity" => 2}]
      })

      assert {:ok, %KitchenRun{status: :applied, surface: :shop} = run} = start()
      assert run == Runs.get(member(), run.id)
      assert [%{store_name: "ICA", total_amount: total}] = Costs.recent_receipts(member(), 5)
      assert Decimal.equal?(total, Decimal.new("89.5"))

      {:ok, _} = Runs.revert(member(), run.id)
      assert Costs.recent_receipts(member(), 5) == []
    end

    test "undo still works after the receipt was deleted by hand" do
      read(%{
        "total" => 10,
        "store_name" => "ICA",
        "purchase_date" => "2026-11-04",
        "items" => []
      })

      {:ok, run} = start()
      [receipt] = Costs.recent_receipts(member(), 5)
      :ok = Costs.delete_receipt(member(), receipt.id)

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(member(), run.id)
    end

    test "keeps its line items, and leaves the pantry and the shopping list alone" do
      list_id = Tore.Streams.shop_list(member(), ~D[2026-11-02])
      # Adding to the list sorts the item into a section once; a receipt asks nothing more.
      expect(Tore.MockLLM, :text, fn _, _, _ -> {:ok, %{"section" => "dairy"}, @usage} end)
      {:ok, _} = Tore.Shop.add_item(member(), list_id, "Mjölk", Decimal.new(1), "l", nil)

      read(%{
        "total" => 89.5,
        "store_name" => "ICA",
        "purchase_date" => "2026-11-04",
        "items" => [
          %{"name" => "MJÖLK 1.5L", "quantity" => 2},
          %{"name" => "ÄGG 12P", "quantity" => 1}
        ]
      })

      assert {:ok, %KitchenRun{status: :applied}} = start()

      receipt =
        Repo.one!(Tore.Costs.Receipt, Tore.Scope.repo_opts(member())) |> Repo.preload(:line_items)

      assert receipt.line_items |> Enum.map(& &1.product_name) |> Enum.sort() == [
               "MJÖLK 1.5L",
               "ÄGG 12P"
             ]

      assert Pantry.list_inventory(member()) == []
      {:ok, %{items: items}} = Tore.Shop.load_list(member(), list_id)
      assert [%{checked: false}] = Map.values(items)
    end

    test "with no store it fails, logging nothing" do
      read(%{"total" => 10, "store_name" => nil, "purchase_date" => "2026-11-04", "items" => []})

      assert {:ok, %KitchenRun{status: :failed, failure_code: :missing_store}} = start()
      assert Costs.recent_receipts(member(), 5) == []
    end

    test "lines that don't add up wait for someone to check the total" do
      cost = %CostEntry{
        store_name: "ICA",
        date: ~D[2026-11-04],
        total: Decimal.new("100"),
        line_items: [
          %{
            name: "MJÖLK",
            quantity: nil,
            unit: nil,
            total_price: Decimal.new("20"),
            category: "dairy"
          }
        ]
      }

      assert {:ok, %KitchenRun{status: :needs_user, question: question} = run} =
               Runs.submit(member(), Receipt, cost, %{})

      assert question =~ "don't add up"
      assert Costs.recent_receipts(member(), 5) == []

      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.confirm(member(), run.id, %{cost | total: Decimal.new("20")})

      assert [%{total_amount: total}] = Costs.recent_receipts(member(), 5)
      assert Decimal.equal?(total, 20)
    end
  end
end
