defmodule Tore.Planning.State do
  defstruct week_start: nil,
            slot_config: %{},
            slots: %{},
            pins: %{}

  @type t :: %__MODULE__{
          week_start: Date.t() | nil,
          slot_config: map(),
          slots: map(),
          pins: map()
        }

  @doc "Whether a slot, or a missing one, is a day the household eats out."
  @spec eating_out?(map() | nil) :: boolean()
  def eating_out?(%{reason: "eating_out"}), do: true
  def eating_out?(_slot), do: false
end
