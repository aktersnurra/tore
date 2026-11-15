defmodule Tore.Shop.Commands do
  defmodule BuildList, do: defstruct([:week_start, :items])
  defmodule AddItem, do: defstruct([:item_id, :name, :quantity, :unit, :section, :added_by])
  defmodule RemoveItem, do: defstruct([:item_id, :removed_by])
  defmodule CheckItem, do: defstruct([:item_id, :checked_by])
  defmodule UncheckItem, do: defstruct([:item_id, :unchecked_by])
  defmodule SetItemSection, do: defstruct([:item_id, :section])

  @type t ::
          %BuildList{}
          | %AddItem{}
          | %RemoveItem{}
          | %CheckItem{}
          | %UncheckItem{}
          | %SetItemSection{}
end
