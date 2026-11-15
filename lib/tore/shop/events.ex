defmodule Tore.Shop.Events do
  defmodule ListBuilt, do: defstruct([:week_start, :items])
  defmodule ItemAdded, do: defstruct([:item_id, :name, :quantity, :unit, :section, :added_by])
  defmodule ItemRemoved, do: defstruct([:item_id, :removed_by])
  defmodule ItemChecked, do: defstruct([:item_id, :checked_by])
  defmodule ItemUnchecked, do: defstruct([:item_id, :unchecked_by])
  defmodule ItemSectionSet, do: defstruct([:item_id, :section])

  @type t ::
          %ListBuilt{}
          | %ItemAdded{}
          | %ItemRemoved{}
          | %ItemChecked{}
          | %ItemUnchecked{}
          | %ItemSectionSet{}
end
