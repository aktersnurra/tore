defmodule Tore.Shop.Commands do
  defmodule BuildList, do: defstruct([:week_start, :items])

  defmodule AddItem,
    do: defstruct([:item_id, :name, :quantity, :unit, :section, :added_by, :deal_id])

  defmodule RemoveItem, do: defstruct([:item_id, :removed_by])
  defmodule CheckItem, do: defstruct([:item_id, :checked_by])
  defmodule UncheckItem, do: defstruct([:item_id, :unchecked_by])
  defmodule SetItemSection, do: defstruct([:item_id, :section])
  defmodule KeepItem, do: defstruct([:item_id, :kept_by])
  defmodule SetItemQuantity, do: defstruct([:item_id, :quantity, :unit, :set_by])

  @type t ::
          %BuildList{}
          | %AddItem{}
          | %RemoveItem{}
          | %CheckItem{}
          | %UncheckItem{}
          | %SetItemSection{}
          | %KeepItem{}
          | %SetItemQuantity{}
end
