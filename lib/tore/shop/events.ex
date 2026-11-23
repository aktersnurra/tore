defmodule Tore.Shop.Events do
  defmodule ListBuilt, do: defstruct([:week_start, :items])
  # `deal_id`: the offer it was put on the list from, if any.
  defmodule ItemAdded,
    do: defstruct([:item_id, :name, :quantity, :unit, :section, :added_by, :deal_id])

  defmodule ItemRemoved, do: defstruct([:item_id, :removed_by])
  defmodule ItemChecked, do: defstruct([:item_id, :checked_by])
  defmodule ItemUnchecked, do: defstruct([:item_id, :unchecked_by])
  defmodule ItemSectionSet, do: defstruct([:item_id, :section])
  # Kept on the list after its offer was withdrawn; it no longer goes by the offer.
  defmodule ItemKept, do: defstruct([:item_id, :kept_by])
  # Its amount changed by hand, from the item's sheet.
  defmodule ItemQuantitySet, do: defstruct([:item_id, :quantity, :unit, :set_by])

  @type t ::
          %ListBuilt{}
          | %ItemAdded{}
          | %ItemRemoved{}
          | %ItemChecked{}
          | %ItemUnchecked{}
          | %ItemSectionSet{}
          | %ItemKept{}
          | %ItemQuantitySet{}
end
