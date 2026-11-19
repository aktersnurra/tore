defmodule Tore.Holidays do
  @moduledoc """
  Swedish public holidays that fall on weekdays, computed, with the afton days people have off
  in practice (midsommarafton, julafton, nyårsafton). Lunch is offered on them (`.docs/specs/lunch.md`).
  """

  @doc """
  Whether `date` is a holiday.

      iex> Tore.Holidays.holiday?(~D[2026-04-03])
      true

      iex> Tore.Holidays.holiday?(~D[2026-04-07])
      false
  """
  @spec holiday?(Date.t()) :: boolean()
  def holiday?(%Date{year: year} = date), do: date in dates(year)

  @doc "The year's holidays, in date order."
  @spec dates(integer()) :: [Date.t()]
  def dates(year) do
    easter = easter(year)

    Enum.sort(
      [
        Date.new!(year, 1, 1),
        Date.new!(year, 1, 6),
        Date.add(easter, -2),
        Date.add(easter, 1),
        Date.new!(year, 5, 1),
        Date.add(easter, 39),
        Date.new!(year, 6, 6),
        midsummer_eve(year),
        Date.new!(year, 12, 24),
        Date.new!(year, 12, 25),
        Date.new!(year, 12, 26),
        Date.new!(year, 12, 31)
      ],
      Date
    )
  end

  # Easter Sunday by the anonymous Gregorian computus.
  defp easter(year) do
    a = rem(year, 19)
    b = div(year, 100)
    c = rem(year, 100)
    d = div(b, 4)
    e = rem(b, 4)
    f = div(b + 8, 25)
    g = div(b - f + 1, 3)
    h = rem(19 * a + b - d - g + 15, 30)
    i = div(c, 4)
    k = rem(c, 4)
    l = rem(32 + 2 * e + 2 * i - h - k, 7)
    m = div(a + 11 * h + 22 * l, 451)
    n = h + l - 7 * m + 114
    Date.new!(year, div(n, 31), rem(n, 31) + 1)
  end

  # The Friday between 19 and 25 June.
  defp midsummer_eve(year) do
    Enum.find(19..25, &(Date.day_of_week(Date.new!(year, 6, &1)) == 5))
    |> then(&Date.new!(year, 6, &1))
  end
end
