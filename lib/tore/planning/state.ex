defmodule Tore.Planning.State do
  defstruct week_start: nil,
            slot_config: %{},
            slots: %{},
            pins: %{},
            days_off: MapSet.new()

  @type t :: %__MODULE__{
          week_start: Date.t() | nil,
          slot_config: map(),
          slots: map(),
          pins: map(),
          days_off: MapSet.t(Date.t())
        }

  @doc """
  Whether `date` is a lunch day: a weekend, a public holiday or a day the household is off. Plan
  offers lunch on it; any day can still have one.
  """
  @spec lunch_day?(t(), Date.t()) :: boolean()
  def lunch_day?(%__MODULE__{days_off: off}, %Date{} = date),
    do: Date.day_of_week(date) >= 6 or Tore.Holidays.holiday?(date) or MapSet.member?(off, date)

  @doc "Whether a slot, or a missing one, is a day the household eats out."
  @spec eating_out?(map() | nil) :: boolean()
  def eating_out?(%{reason: "eating_out"}), do: true
  def eating_out?(_slot), do: false
end
