defmodule Tore.Clock do
  @moduledoc """
  The household's clock: the server's local time, so set `TZ` to the household's time zone.
  Calendar dates (today, this week, tonight) come from here, so every screen and the home pick
  agree on which day it is. Stored timestamps stay UTC.
  """

  @spec now() :: NaiveDateTime.t()
  def now, do: NaiveDateTime.local_now()

  @spec today() :: Date.t()
  def today, do: NaiveDateTime.to_date(now())

  @doc "The household's date at a stored (UTC) moment."
  @spec date_of(DateTime.t()) :: Date.t()
  def date_of(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
    |> NaiveDateTime.to_date()
  end
end
