defmodule Tore.Planning.DeciderTest do
  use ExUnit.Case, async: true

  alias Tore.Planning.{Decider, State, Commands, Events}

  defp state_with_slot(slot_key, recipe_id \\ 1) do
    %State{
      slots: %{slot_key => %{recipe_id: recipe_id, servings: 2, skipped: false, leftover: false}}
    }
  end

  defp state_with_pin(slot_key) do
    %State{pins: %{slot_key => %{type: :recipe, recipe_id: 1}}}
  end

  test "initial/0 returns empty plan state" do
    assert %State{week_start: nil, slots: %{}, pins: %{}} = Decider.initial()
  end

  describe "decide/2 — AssignRecipe" do
    test "emits RecipeAssigned" do
      cmd = %Commands.AssignRecipe{slot_key: "mon_dinner", recipe_id: 42, servings: 4}

      assert {:ok, [%Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: 42, servings: 4}]} =
               Decider.decide(cmd, Decider.initial())
    end
  end

  describe "decide/2 — RemoveRecipe" do
    test "returns :slot_empty when slot missing" do
      cmd = %Commands.RemoveRecipe{slot_key: "mon_dinner"}
      assert {:error, :slot_empty} = Decider.decide(cmd, Decider.initial())
    end

    test "emits RecipeRemoved when slot filled" do
      cmd = %Commands.RemoveRecipe{slot_key: "mon_dinner"}

      assert {:ok, [%Events.RecipeRemoved{slot_key: "mon_dinner"}]} =
               Decider.decide(cmd, state_with_slot("mon_dinner"))
    end
  end

  describe "decide/2 — SetServings" do
    test "returns :slot_empty when slot missing" do
      cmd = %Commands.SetServings{slot_key: "mon_dinner", servings: 6}
      assert {:error, :slot_empty} = Decider.decide(cmd, Decider.initial())
    end

    test "emits ServingsChanged when slot filled" do
      cmd = %Commands.SetServings{slot_key: "mon_dinner", servings: 6}

      assert {:ok, [%Events.ServingsChanged{slot_key: "mon_dinner", servings: 6}]} =
               Decider.decide(cmd, state_with_slot("mon_dinner"))
    end
  end

  describe "decide/2 — PinSlot" do
    test "emits SlotPinned" do
      pin = %{type: :recipe, recipe_id: 5}
      cmd = %Commands.PinSlot{slot_key: "wed_dinner", pin: pin}

      assert {:ok, [%Events.SlotPinned{slot_key: "wed_dinner", pin: ^pin}]} =
               Decider.decide(cmd, Decider.initial())
    end
  end

  describe "decide/2 — UnpinSlot" do
    test "returns :not_pinned when no pin" do
      cmd = %Commands.UnpinSlot{slot_key: "wed_dinner"}
      assert {:error, :not_pinned} = Decider.decide(cmd, Decider.initial())
    end

    test "emits SlotUnpinned when pinned" do
      cmd = %Commands.UnpinSlot{slot_key: "wed_dinner"}

      assert {:ok, [%Events.SlotUnpinned{slot_key: "wed_dinner"}]} =
               Decider.decide(cmd, state_with_pin("wed_dinner"))
    end
  end

  describe "decide/2 — EatOut" do
    test "works on an empty day, unlike a plain skip" do
      assert {:ok, [%Events.MealSkipped{slot_key: "mon_dinner", reason: "eating_out"}]} =
               Decider.decide(%Commands.EatOut{slot_key: "mon_dinner"}, Decider.initial())
    end

    test "changes nothing if the day is already eating out" do
      event = %Events.MealSkipped{slot_key: "mon_dinner", reason: "eating_out"}
      state = Decider.evolve(Decider.initial(), event)

      assert {:ok, []} = Decider.decide(%Commands.EatOut{slot_key: "mon_dinner"}, state)
    end
  end

  describe "decide/2 — SkipMeal" do
    test "returns :slot_empty when slot missing" do
      cmd = %Commands.SkipMeal{slot_key: "mon_dinner"}
      assert {:error, :slot_empty} = Decider.decide(cmd, Decider.initial())
    end

    test "emits MealSkipped when slot filled" do
      cmd = %Commands.SkipMeal{slot_key: "mon_dinner"}

      assert {:ok, [%Events.MealSkipped{slot_key: "mon_dinner"}]} =
               Decider.decide(cmd, state_with_slot("mon_dinner"))
    end
  end

  describe "decide/2 — MarkLeftover" do
    test "returns :slot_empty when slot missing" do
      cmd = %Commands.MarkLeftover{slot_key: "mon_dinner"}
      assert {:error, :slot_empty} = Decider.decide(cmd, Decider.initial())
    end

    test "emits LeftoverMarked when slot filled" do
      cmd = %Commands.MarkLeftover{slot_key: "mon_dinner"}

      assert {:ok, [%Events.LeftoverMarked{slot_key: "mon_dinner"}]} =
               Decider.decide(cmd, state_with_slot("mon_dinner"))
    end
  end

  describe "evolve/2" do
    test "RecipeAssigned adds slot with skipped: false, leftover: false" do
      event = %Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: 7, servings: 3}
      state = Decider.evolve(Decider.initial(), event)

      assert state.slots["mon_dinner"] == %{
               recipe_id: 7,
               servings: 3,
               skipped: false,
               leftover: false
             }
    end

    test "RecipeRemoved deletes slot" do
      state = state_with_slot("mon_dinner")
      event = %Events.RecipeRemoved{slot_key: "mon_dinner"}
      assert %State{slots: %{}} = Decider.evolve(state, event)
    end

    test "ServingsChanged updates servings" do
      state = state_with_slot("mon_dinner")
      event = %Events.ServingsChanged{slot_key: "mon_dinner", servings: 8}
      updated = Decider.evolve(state, event)
      assert updated.slots["mon_dinner"].servings == 8
    end

    test "SlotPinned adds pin" do
      pin = %{type: :free_text, text: "something with salmon"}
      event = %Events.SlotPinned{slot_key: "thu_dinner", pin: pin}
      state = Decider.evolve(Decider.initial(), event)
      assert state.pins["thu_dinner"] == pin
    end

    test "SlotUnpinned removes pin" do
      state = state_with_pin("wed_dinner")
      event = %Events.SlotUnpinned{slot_key: "wed_dinner"}
      updated = Decider.evolve(state, event)
      assert updated.pins == %{}
    end

    test "MealSkipped marks slot skipped: true" do
      state = state_with_slot("mon_dinner")
      event = %Events.MealSkipped{slot_key: "mon_dinner"}
      updated = Decider.evolve(state, event)
      assert updated.slots["mon_dinner"].skipped == true
    end

    test "a plain MealSkipped keeps the recipe and has no reason" do
      state = state_with_slot("mon_dinner")
      updated = Decider.evolve(state, %Events.MealSkipped{slot_key: "mon_dinner"})
      assert updated.slots["mon_dinner"].recipe_id == state.slots["mon_dinner"].recipe_id
      assert updated.slots["mon_dinner"].reason == nil
    end

    test "eating out clears the recipe" do
      state = state_with_slot("mon_dinner")
      event = %Events.MealSkipped{slot_key: "mon_dinner", reason: "eating_out"}
      slot = Decider.evolve(state, event).slots["mon_dinner"]

      assert slot.recipe_id == nil
      assert slot.skipped == true
      assert State.eating_out?(slot)
    end

    test "eating out lands on an empty day" do
      event = %Events.MealSkipped{slot_key: "mon_dinner", reason: "eating_out"}
      assert State.eating_out?(Decider.evolve(Decider.initial(), event).slots["mon_dinner"])
    end

    test "assigning a recipe ends eating out" do
      state =
        Decider.evolve(Decider.initial(), %Events.MealSkipped{
          slot_key: "mon_dinner",
          reason: "eating_out"
        })

      updated =
        Decider.evolve(state, %Events.RecipeAssigned{
          slot_key: "mon_dinner",
          recipe_id: 1,
          servings: 2
        })

      refute State.eating_out?(updated.slots["mon_dinner"])
      assert updated.slots["mon_dinner"].skipped == false
    end

    test "LeftoverMarked marks slot leftover: true" do
      state = state_with_slot("mon_dinner")
      event = %Events.LeftoverMarked{slot_key: "mon_dinner"}
      updated = Decider.evolve(state, event)
      assert updated.slots["mon_dinner"].leftover == true
    end
  end
end
