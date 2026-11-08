defmodule Tore.Streams do
  @moduledoc """
  Ids for a household's weekly event streams: `plan:<household>:<week start>` and
  `shop_list:<household>:<week start>`. The week start is a Monday.
  """

  alias Tore.Scope

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

  defp id(kind, %Scope{household_id: household_id}, date),
    do: "#{kind}:#{household_id}:#{Date.to_iso8601(monday(date))}"
end
