defmodule Tore.Planning.Decider do
  alias Tore.Planning.{Commands, Events, State}

  @spec initial() :: State.t()
  def initial, do: %State{}

  @spec decide(Commands.t(), State.t()) :: {:ok, [Events.t()]} | {:error, term()}
  def decide(%Commands.AssignRecipe{slot_key: sk, recipe_id: rid, servings: sv}, _state) do
    {:ok, [%Events.RecipeAssigned{slot_key: sk, recipe_id: rid, servings: sv}]}
  end

  def decide(%Commands.RemoveRecipe{slot_key: sk}, state) do
    if Map.has_key?(state.slots, sk) do
      {:ok, [%Events.RecipeRemoved{slot_key: sk}]}
    else
      {:error, :slot_empty}
    end
  end

  def decide(%Commands.SetServings{slot_key: sk, servings: sv}, state) do
    if Map.has_key?(state.slots, sk) do
      {:ok, [%Events.ServingsChanged{slot_key: sk, servings: sv}]}
    else
      {:error, :slot_empty}
    end
  end

  def decide(%Commands.PinSlot{slot_key: sk, pin: pin}, _state) do
    {:ok, [%Events.SlotPinned{slot_key: sk, pin: pin}]}
  end

  def decide(%Commands.UnpinSlot{slot_key: sk}, state) do
    if Map.has_key?(state.pins, sk) do
      {:ok, [%Events.SlotUnpinned{slot_key: sk}]}
    else
      {:error, :not_pinned}
    end
  end

  def decide(%Commands.SkipMeal{slot_key: sk}, state) do
    if Map.has_key?(state.slots, sk) do
      {:ok, [%Events.MealSkipped{slot_key: sk}]}
    else
      {:error, :slot_empty}
    end
  end

  # Unlike a plain skip, this works on an empty day. Saying it again with a place or an amount
  # updates the day, keeping what it isn't given; saying nothing new changes nothing.
  def decide(%Commands.EatOut{slot_key: sk} = cmd, state) do
    now = if State.eating_out?(state.slots[sk]), do: state.slots[sk], else: %{}

    with {:ok, amount} <- amount(cmd.amount, now[:amount]) do
      place = pick(cmd.place, now[:place])

      if now != %{} and place == now.place and amount == now.amount,
        do: {:ok, []},
        else:
          {:ok,
           [%Events.MealSkipped{slot_key: sk, reason: "eating_out", place: place, amount: amount}]}
    end
  end

  def decide(%Commands.MarkLeftover{slot_key: sk}, state) do
    if Map.has_key?(state.slots, sk) do
      {:ok, [%Events.LeftoverMarked{slot_key: sk}]}
    else
      {:error, :slot_empty}
    end
  end

  defp pick(nil, kept), do: kept
  defp pick("", _kept), do: nil
  defp pick(given, _kept) when is_binary(given), do: String.trim(given)

  defp amount(nil, kept), do: {:ok, kept}
  defp amount("", _kept), do: {:ok, nil}

  defp amount(given, _kept) do
    case given |> to_string() |> String.trim() |> String.replace(",", ".") |> Decimal.parse() do
      {%Decimal{sign: 1} = d, ""} -> {:ok, d |> Decimal.normalize() |> Decimal.to_string(:normal)}
      _ -> {:error, :invalid_amount}
    end
  end

  @spec evolve(State.t(), Events.t()) :: State.t()
  def evolve(state, %Events.RecipeAssigned{slot_key: sk, recipe_id: rid, servings: sv}) do
    slot = %{recipe_id: rid, servings: sv, skipped: false, leftover: false}
    %{state | slots: Map.put(state.slots, sk, slot)}
  end

  def evolve(state, %Events.RecipeRemoved{slot_key: sk}) do
    %{state | slots: Map.delete(state.slots, sk)}
  end

  def evolve(state, %Events.ServingsChanged{slot_key: sk, servings: sv}) do
    %{state | slots: update_in(state.slots, [sk], &Map.put(&1, :servings, sv))}
  end

  def evolve(state, %Events.SlotPinned{slot_key: sk, pin: pin}) do
    %{state | pins: Map.put(state.pins, sk, pin)}
  end

  def evolve(state, %Events.SlotUnpinned{slot_key: sk}) do
    %{state | pins: Map.delete(state.pins, sk)}
  end

  # Eating out cancels the day's recipe, and may land on a day that has none.
  def evolve(state, %Events.MealSkipped{slot_key: sk, reason: "eating_out"} = e) do
    slot = %{
      recipe_id: nil,
      servings: nil,
      skipped: true,
      leftover: false,
      reason: "eating_out",
      place: e.place,
      amount: e.amount
    }

    %{state | slots: Map.put(state.slots, sk, slot)}
  end

  def evolve(state, %Events.MealSkipped{slot_key: sk}) do
    slot =
      state.slots
      |> Map.fetch!(sk)
      |> Map.merge(%{skipped: true, reason: nil})
      |> Map.drop([:place, :amount])

    %{state | slots: Map.put(state.slots, sk, slot)}
  end

  def evolve(state, %Events.LeftoverMarked{slot_key: sk}) do
    %{state | slots: update_in(state.slots, [sk], &Map.put(&1, :leftover, true))}
  end
end
