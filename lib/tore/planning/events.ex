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

  @modules Map.new(
             [
               RecipeAssigned,
               RecipeRemoved,
               ServingsChanged,
               SlotPinned,
               SlotUnpinned,
               MealSkipped,
               LeftoverMarked
             ],
             &{&1 |> Module.split() |> List.last(), &1}
           )

  @doc "An event as JSON, for a run that carries the events it will append."
  @spec to_json(t()) :: map()
  def to_json(%module{} = event) do
    type = module |> Module.split() |> List.last()
    ^module = Map.fetch!(@modules, type)

    %{
      "type" => type,
      "data" => event |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end)
    }
  end

  @doc "Strict: an unknown type or field raises."
  @spec from_json(map()) :: t()
  def from_json(%{"type" => type, "data" => data} = json) when map_size(json) == 2 do
    module = Map.fetch!(@modules, type)

    fields =
      module.__struct__() |> Map.from_struct() |> Map.keys() |> Map.new(&{to_string(&1), &1})

    struct!(module, Map.new(data, fn {k, v} -> {Map.fetch!(fields, k), v} end))
  end
end
