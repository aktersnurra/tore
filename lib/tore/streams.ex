defmodule Tore.Streams do
  @moduledoc """
  Ids for a household's weekly event streams: `plan:<household>:<week start>` and
  `shop_list:<household>:<week start>`. The week start is a Monday.
  """

  alias Tore.Scope

  @days ~w(mon tue wed thu fri sat sun)

  @spec plan(Scope.t(), Date.t()) :: String.t()
  def plan(%Scope{} = scope, %Date{} = date), do: id("plan", scope, date)

  @spec shop_list(Scope.t(), Date.t()) :: String.t()
  def shop_list(%Scope{} = scope, %Date{} = date), do: id("shop_list", scope, date)

  @doc "The Monday of the week a stream id names."
  @spec week_start(String.t()) :: Date.t()
  def week_start(stream_id) do
    [_kind, _household, date] = String.split(stream_id, ":")
    Date.from_iso8601!(date)
  end

  @doc "The Monday of the week `date` falls in."
  @spec monday(Date.t()) :: Date.t()
  def monday(%Date{} = date), do: Date.add(date, 1 - Date.day_of_week(date))

  @doc """
  The slot key for `date`'s weekday and `meal`, dinner unless lunch is asked for.

      iex> Tore.Streams.slot_key(~D[2026-06-15])
      "mon_dinner"

      iex> Tore.Streams.slot_key(~D[2026-06-21], :lunch)
      "sun_lunch"
  """
  @spec slot_key(Date.t(), :dinner | :lunch) :: String.t()
  def slot_key(%Date{} = date, meal \\ :dinner) when meal in [:dinner, :lunch],
    do: "#{Enum.at(@days, Date.day_of_week(date) - 1)}_#{meal}"

  @doc """
  Where a slot falls in the week, for ordering: its day, then lunch before dinner.

      iex> Tore.Streams.slot_order("sat_lunch") < Tore.Streams.slot_order("sat_dinner")
      true

      iex> Tore.Streams.slot_order("fri_dinner") < Tore.Streams.slot_order("sat_lunch")
      true
  """
  @spec slot_order(String.t()) :: {non_neg_integer(), 0 | 1}
  def slot_order(slot_key) do
    [day, meal] = String.split(slot_key, "_", parts: 2)
    {Enum.find_index(@days, &(&1 == day)) || length(@days), if(meal == "lunch", do: 0, else: 1)}
  end

  @doc "The ISO week number of `date`."
  @spec week_number(Date.t()) :: 1..53
  def week_number(%Date{} = date) do
    {_year, week} = :calendar.iso_week_number(Date.to_erl(date))
    week
  end

  defp id(kind, %Scope{household_id: household_id}, date),
    do: "#{kind}:#{household_id}:#{Date.to_iso8601(monday(date))}"
end
