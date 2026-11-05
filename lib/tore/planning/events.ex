defmodule Tore.Planning.Events do
  defmodule RecipeAssigned, do: defstruct([:slot_key, :recipe_id, :servings])
  defmodule RecipeRemoved, do: defstruct([:slot_key])
  defmodule ServingsChanged, do: defstruct([:slot_key, :servings])
  defmodule SlotPinned, do: defstruct([:slot_key, :pin])
  defmodule SlotUnpinned, do: defstruct([:slot_key])
  # reason is nil for a plain skip, or "eating_out". Older events have none.
  defmodule MealSkipped, do: defstruct([:slot_key, :reason])
  defmodule LeftoverMarked, do: defstruct([:slot_key])

  @type t ::
          %RecipeAssigned{}
          | %RecipeRemoved{}
          | %ServingsChanged{}
          | %SlotPinned{}
          | %SlotUnpinned{}
          | %MealSkipped{}
          | %LeftoverMarked{}
end
