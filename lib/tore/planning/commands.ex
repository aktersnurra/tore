defmodule Tore.Planning.Commands do
  defmodule AssignRecipe, do: defstruct([:slot_key, :recipe_id, :servings])
  defmodule RemoveRecipe, do: defstruct([:slot_key])
  defmodule SetServings, do: defstruct([:slot_key, :servings])
  defmodule PinSlot, do: defstruct([:slot_key, :pin])
  defmodule UnpinSlot, do: defstruct([:slot_key])
  defmodule SkipMeal, do: defstruct([:slot_key])
  # place and amount: nil keeps what the day has, "" clears it. amount is a number or text.
  defmodule EatOut, do: defstruct([:slot_key, :place, :amount])
  defmodule MarkLeftover, do: defstruct([:slot_key])

  @type t ::
          %AssignRecipe{}
          | %RemoveRecipe{}
          | %SetServings{}
          | %PinSlot{}
          | %UnpinSlot{}
          | %SkipMeal{}
          | %EatOut{}
          | %MarkLeftover{}
end
