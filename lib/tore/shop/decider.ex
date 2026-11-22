defmodule Tore.Shop.Decider do
  alias Tore.Shop.{Commands, Events, State}

  @spec initial() :: State.t()
  def initial, do: %State{}

  @spec decide(Commands.t(), State.t()) :: {:ok, [Events.t()]} | {:error, term()}
  def decide(%Commands.BuildList{week_start: ws, items: items}, _state) do
    {:ok, [%Events.ListBuilt{week_start: ws, items: items}]}
  end

  def decide(%Commands.AddItem{} = cmd, _state) do
    {:ok,
     [
       %Events.ItemAdded{
         item_id: cmd.item_id,
         name: cmd.name,
         quantity: cmd.quantity,
         unit: cmd.unit,
         section: cmd.section,
         added_by: cmd.added_by,
         deal_id: cmd.deal_id
       }
     ]}
  end

  def decide(%Commands.RemoveItem{item_id: id, removed_by: by}, state) do
    if Map.has_key?(state.items, id) do
      {:ok, [%Events.ItemRemoved{item_id: id, removed_by: by}]}
    else
      {:error, :item_not_found}
    end
  end

  def decide(%Commands.CheckItem{item_id: id, checked_by: by}, state) do
    if Map.has_key?(state.items, id) do
      {:ok, [%Events.ItemChecked{item_id: id, checked_by: by}]}
    else
      {:error, :item_not_found}
    end
  end

  def decide(%Commands.UncheckItem{item_id: id, unchecked_by: by}, state) do
    if Map.has_key?(state.items, id) do
      {:ok, [%Events.ItemUnchecked{item_id: id, unchecked_by: by}]}
    else
      {:error, :item_not_found}
    end
  end

  def decide(%Commands.SetItemSection{item_id: id, section: section}, state) do
    if Map.has_key?(state.items, id) do
      {:ok, [%Events.ItemSectionSet{item_id: id, section: section}]}
    else
      {:error, :item_not_found}
    end
  end

  def decide(%Commands.KeepItem{item_id: id, kept_by: by}, state) do
    if Map.has_key?(state.items, id) do
      {:ok, [%Events.ItemKept{item_id: id, kept_by: by}]}
    else
      {:error, :item_not_found}
    end
  end

  @section_atoms ~w(produce meat fish dairy deli frozen bread dry_goods canned beverages herbs_spices condiments household other)a

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {"section", v} -> {:section, to_section_atom(v)}
      {:section, v} -> {:section, to_section_atom(v)}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp to_section_atom(v) when is_atom(v) and not is_nil(v) do
    if v in @section_atoms, do: v, else: :other
  end

  defp to_section_atom(v) when is_binary(v) do
    atom = String.to_atom(v)
    if atom in @section_atoms, do: atom, else: :other
  end

  defp to_section_atom(_), do: :other

  @spec evolve(State.t(), Events.t()) :: State.t()
  def evolve(state, %Events.ListBuilt{week_start: ws, items: items}) do
    item_map =
      Map.new(items, fn item ->
        item = atomize(item)
        {item.id, item}
      end)

    %{state | week_start: ws, items: item_map}
  end

  def evolve(state, %Events.ItemAdded{} = e) do
    item = %{
      id: e.item_id,
      name: e.name,
      quantity: e.quantity,
      unit: e.unit,
      # Section needs to be the atom form regardless of whether this event
      # was freshly decided (atom from add_item) or rehydrated from the
      # event store (string from Jason). The render groups items by atom
      # section keys, so a string here silently drops the item from view.
      section: to_section_atom(e.section),
      checked: false,
      deal_id: e.deal_id
    }

    %{state | items: Map.put(state.items, e.item_id, item)}
  end

  def evolve(state, %Events.ItemRemoved{item_id: id}) do
    %{state | items: Map.delete(state.items, id)}
  end

  def evolve(state, %Events.ItemChecked{item_id: id}) do
    %{state | items: update_in(state.items, [id], &Map.put(&1, :checked, true))}
  end

  def evolve(state, %Events.ItemUnchecked{item_id: id}) do
    %{state | items: update_in(state.items, [id], &Map.put(&1, :checked, false))}
  end

  def evolve(state, %Events.ItemKept{item_id: id}) do
    %{state | items: update_in(state.items, [id], &Map.put(&1, :deal_id, nil))}
  end

  def evolve(state, %Events.ItemSectionSet{item_id: id, section: section}) do
    %{
      state
      | items: update_in(state.items, [id], &Map.put(&1, :section, to_section_atom(section)))
    }
  end
end
