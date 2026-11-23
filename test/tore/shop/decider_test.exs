defmodule Tore.Shop.DeciderTest do
  use ExUnit.Case, async: true

  alias Tore.Shop.{Decider, State, Commands, Events}

  defp item(id \\ "item-1"), do: %{id: id, name: "Milk", quantity: nil, unit: "l", checked: false}

  defp state_with_item(id \\ "item-1") do
    %State{items: %{id => item(id)}}
  end

  test "initial/0 returns empty grocery state" do
    assert %State{week_start: nil, items: %{}} = Decider.initial()
  end

  describe "decide/2 — BuildList" do
    test "emits ListBuilt with items" do
      items = [item("a"), item("b")]
      cmd = %Commands.BuildList{week_start: ~D[2026-04-27], items: items}

      assert {:ok, [%Events.ListBuilt{week_start: ~D[2026-04-27], items: ^items}]} =
               Decider.decide(cmd, Decider.initial())
    end
  end

  describe "decide/2 — AddItem" do
    test "emits ItemAdded" do
      cmd = %Commands.AddItem{item_id: "x", name: "Eggs", quantity: nil, unit: nil, added_by: 1}

      assert {:ok, [%Events.ItemAdded{item_id: "x", name: "Eggs"}]} =
               Decider.decide(cmd, Decider.initial())
    end
  end

  describe "decide/2 — RemoveItem" do
    test "returns :item_not_found when missing" do
      cmd = %Commands.RemoveItem{item_id: "missing", removed_by: 1}
      assert {:error, :item_not_found} = Decider.decide(cmd, Decider.initial())
    end

    test "emits ItemRemoved when present" do
      cmd = %Commands.RemoveItem{item_id: "item-1", removed_by: 1}

      assert {:ok, [%Events.ItemRemoved{item_id: "item-1"}]} =
               Decider.decide(cmd, state_with_item())
    end
  end

  describe "decide/2 — SetItemQuantity" do
    test "returns :item_not_found when missing" do
      cmd = %Commands.SetItemQuantity{item_id: "missing", quantity: Decimal.new(2), unit: "l"}
      assert {:error, :item_not_found} = Decider.decide(cmd, Decider.initial())
    end

    test "emits ItemQuantitySet, and the item takes the new amount" do
      cmd = %Commands.SetItemQuantity{
        item_id: "item-1",
        quantity: Decimal.new(2),
        unit: "l",
        set_by: 1
      }

      assert {:ok, [%Events.ItemQuantitySet{item_id: "item-1"} = event]} =
               Decider.decide(cmd, state_with_item())

      assert %{quantity: quantity, unit: "l"} =
               Decider.evolve(state_with_item(), event).items["item-1"]

      assert Decimal.equal?(quantity, 2)
    end
  end

  describe "decide/2 — CheckItem" do
    test "returns :item_not_found when missing" do
      cmd = %Commands.CheckItem{item_id: "missing", checked_by: 1}
      assert {:error, :item_not_found} = Decider.decide(cmd, Decider.initial())
    end

    test "emits ItemChecked when present" do
      cmd = %Commands.CheckItem{item_id: "item-1", checked_by: 1}

      assert {:ok, [%Events.ItemChecked{item_id: "item-1"}]} =
               Decider.decide(cmd, state_with_item())
    end
  end

  describe "decide/2 — UncheckItem" do
    test "returns :item_not_found when missing" do
      cmd = %Commands.UncheckItem{item_id: "missing", unchecked_by: 1}
      assert {:error, :item_not_found} = Decider.decide(cmd, Decider.initial())
    end

    test "emits ItemUnchecked when present" do
      cmd = %Commands.UncheckItem{item_id: "item-1", unchecked_by: 1}

      assert {:ok, [%Events.ItemUnchecked{item_id: "item-1"}]} =
               Decider.decide(cmd, state_with_item())
    end
  end

  describe "evolve/2" do
    test "ListBuilt sets week_start and items keyed by id" do
      items = [item("a"), item("b")]
      event = %Events.ListBuilt{week_start: ~D[2026-04-27], items: items}
      state = Decider.evolve(Decider.initial(), event)
      assert state.week_start == ~D[2026-04-27]
      assert Map.has_key?(state.items, "a")
      assert Map.has_key?(state.items, "b")
    end

    test "ItemAdded adds item with checked: false" do
      event = %Events.ItemAdded{
        item_id: "z",
        name: "Butter",
        quantity: nil,
        unit: "g",
        added_by: 1
      }

      state = Decider.evolve(Decider.initial(), event)

      assert state.items["z"] == %{
               id: "z",
               name: "Butter",
               quantity: nil,
               unit: "g",
               # Section is normalised to :other when missing/unknown so the
               # render's atom-keyed grouping always finds a bucket.
               section: :other,
               checked: false,
               deal_id: nil
             }
    end

    test "an item put on from an offer keeps the offer until it's kept without it" do
      added = %Events.ItemAdded{item_id: "z", name: "Lax", deal_id: 7}
      state = Decider.evolve(Decider.initial(), added)
      assert state.items["z"].deal_id == 7

      assert {:ok, [kept]} = Decider.decide(%Commands.KeepItem{item_id: "z", kept_by: 1}, state)
      assert Decider.evolve(state, kept).items["z"].deal_id == nil
    end

    test "keeping an item not on the list is refused" do
      assert {:error, :item_not_found} =
               Decider.decide(%Commands.KeepItem{item_id: "nope"}, Decider.initial())
    end

    test "ItemAdded normalises a string section to its atom form (rehydration)" do
      # EventStore.load decodes JSON with keys: :atoms but leaves values
      # untouched, so a rehydrated event's `section` arrives as a string.
      # Render groups by atom keys, so string sections were silently dropped.
      event = %Events.ItemAdded{
        item_id: "z",
        name: "Mjölk",
        quantity: nil,
        unit: nil,
        section: "dairy",
        added_by: 1
      }

      state = Decider.evolve(Decider.initial(), event)
      assert state.items["z"].section == :dairy
    end

    test "ItemAdded normalises an unknown section to :other" do
      event = %Events.ItemAdded{
        item_id: "z",
        name: "Mystery",
        quantity: nil,
        unit: nil,
        section: "unknown_section_label",
        added_by: 1
      }

      state = Decider.evolve(Decider.initial(), event)
      assert state.items["z"].section == :other
    end

    test "ItemRemoved removes item" do
      state = state_with_item()
      event = %Events.ItemRemoved{item_id: "item-1", removed_by: 1}
      assert %State{items: %{}} = Decider.evolve(state, event)
    end

    test "ItemChecked marks checked: true" do
      state = state_with_item()
      event = %Events.ItemChecked{item_id: "item-1", checked_by: 1}
      updated = Decider.evolve(state, event)
      assert updated.items["item-1"].checked == true
    end

    test "ItemUnchecked marks checked: false" do
      state = %State{items: %{"item-1" => Map.put(item(), :checked, true)}}
      event = %Events.ItemUnchecked{item_id: "item-1", unchecked_by: 1}
      updated = Decider.evolve(state, event)
      assert updated.items["item-1"].checked == false
    end
  end
end
