defmodule Tore.Harness.ReceiptIngestionTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Costs.Receipt
  alias Tore.Harness.Artifact.{CostEntry, PantryBeliefUpdate}
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State
  alias Tore.{Pantry, Shop}

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  setup do
    user = user_fixture(name: "Gustaf")
    %{user: user}
  end

  # No `text` expectation: a receipt making a name-matching call fails the test.
  defp dispatch_receipt do
    expect(Tore.MockLLM, :vision, fn _blobs, _system, _user, _opts ->
      {:ok,
       %{
         "total" => 89.5,
         "store_name" => "ICA",
         "purchase_date" => "2026-11-04",
         "items" => [
           %{"name" => "MJÖLK 1.5L", "quantity" => 2, "unit" => "st", "category" => "dairy"},
           %{"name" => "ÄGG 12P", "quantity" => 1, "unit" => "st", "category" => "other"}
         ]
       }, @usage}
    end)

    {:ok, %State.NeedsUser{} = state} =
      Orchestrator.dispatch(:receipt_ingestion_run, %{
        household_id: Tore.Household.get_household!().id,
        user_id: nil,
        image_binary: <<255, 216, 255>>
      })

    state
  end

  test "a receipt proposes a cost and nothing for the pantry" do
    state = dispatch_receipt()

    assert Enum.any?(state.artifacts, &match?(%CostEntry{}, &1))
    refute Enum.any?(state.artifacts, &match?(%PantryBeliefUpdate{}, &1))
  end

  test "saving a receipt stores its cost and line items", %{user: user} do
    state = dispatch_receipt()
    cost = Enum.find(state.artifacts, &match?(%CostEntry{}, &1))

    assert {:ok, %State.Applied{}} = Orchestrator.commit_receipt(state.stream_id, cost, user.id)

    receipt = Repo.one!(Receipt) |> Repo.preload(:line_items)
    assert receipt.store_name == "ICA"
    assert Decimal.equal?(receipt.total_amount, Decimal.from_float(89.5))

    assert Enum.map(receipt.line_items, & &1.product_name) |> Enum.sort() == [
             "MJÖLK 1.5L",
             "ÄGG 12P"
           ]
  end

  test "saving a receipt leaves the pantry and the shopping list alone", %{user: user} do
    list_id = "shop_list:2026-11-02"
    # Adding to the list classifies the item once. Any further call would fail.
    expect(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, %{"section" => "dairy"}, @usage}
    end)

    {:ok, _} = Shop.add_item(list_id, "Mjölk", Decimal.new(1), "l", nil)

    state = dispatch_receipt()
    cost = Enum.find(state.artifacts, &match?(%CostEntry{}, &1))
    assert {:ok, %State.Applied{}} = Orchestrator.commit_receipt(state.stream_id, cost, user.id)

    assert Pantry.list_inventory(home_scope()) == []
    {:ok, %{items: items}} = Shop.load_list(list_id)
    assert [%{checked: false}] = Map.values(items)
  end
end
