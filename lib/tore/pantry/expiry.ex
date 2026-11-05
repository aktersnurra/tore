defmodule Tore.Pantry.Expiry do
  @moduledoc """
  Decides a pantry row's expiry date from what was just observed. Pure.

  A printed date beats a guess, and a date the household set beats both until
  the item is bought again. Seeing an item again doesn't make it fresher, so a
  photo never extends a date. Buying it starts over.
  """

  @max_shelf_life_days 3650

  @type source :: String.t() | nil
  @type current :: %{
          required(:expires_at) => Date.t() | nil,
          required(:expires_source) => source(),
          optional(atom()) => term()
        }
  @type observation :: %{
          optional(:provenance) => String.t() | nil,
          optional(:expires_on) => Date.t() | nil,
          optional(atom()) => term()
        }

  @spec next(current(), observation(), pos_integer() | nil, Date.t()) ::
          {Date.t() | nil, source()}
  def next(current, observation, shelf_life_days, today) do
    if bought?(observation) do
      estimate(shelf_life_days, today)
    else
      next_from_photo(current, observation[:expires_on], shelf_life_days, today)
    end
  end

  @doc "A photo shows what's there. Every other source means the item just came in."
  @spec bought?(observation()) :: boolean()
  def bought?(observation), do: observation[:provenance] != "vision"

  defp next_from_photo(%{expires_source: "manual"} = current, _printed, _days, _today),
    do: keep(current)

  defp next_from_photo(_current, %Date{} = printed, _days, _today), do: {printed, "label"}

  defp next_from_photo(%{expires_at: %Date{}} = current, nil, _days, _today), do: keep(current)

  defp next_from_photo(_current, nil, days, today), do: estimate(days, today)

  defp keep(current), do: {current.expires_at, current.expires_source}

  defp estimate(nil, _today), do: {nil, nil}
  defp estimate(days, today), do: {Date.add(today, days), "estimate"}

  @doc "A shelf life in days, or nil if it's outside what any food could keep."
  @spec parse_shelf_life(term()) :: pos_integer() | nil
  def parse_shelf_life(days) when is_integer(days) and days in 1..@max_shelf_life_days, do: days
  def parse_shelf_life(_days), do: nil

  @spec parse_date(term()) :: Date.t() | nil
  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  def parse_date(_value), do: nil
end
