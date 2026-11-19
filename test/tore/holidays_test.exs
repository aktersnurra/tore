defmodule Tore.HolidaysTest do
  use ExUnit.Case, async: true

  alias Tore.Holidays

  doctest Tore.Holidays

  test "Easter's holidays move with Easter" do
    # Easter Sunday: 2025-04-20, 2026-04-05, 2027-03-28, 2028-04-16
    for {year, sunday} <- [
          {2025, ~D[2025-04-20]},
          {2026, ~D[2026-04-05]},
          {2027, ~D[2027-03-28]},
          {2028, ~D[2028-04-16]}
        ] do
      dates = Holidays.dates(year)
      assert Date.add(sunday, -2) in dates, "långfredagen #{year}"
      assert Date.add(sunday, 1) in dates, "annandag påsk #{year}"
      assert Date.add(sunday, 39) in dates, "Kristi himmelsfärd #{year}"
      refute sunday in dates
    end
  end

  test "midsommarafton is the Friday between 19 and 25 June" do
    assert ~D[2025-06-20] in Holidays.dates(2025)
    assert ~D[2026-06-19] in Holidays.dates(2026)
    assert ~D[2027-06-25] in Holidays.dates(2027)
  end

  test "the fixed days, and an ordinary day isn't one" do
    for d <-
          ~w[2026-01-01 2026-01-06 2026-05-01 2026-06-06 2026-12-24 2026-12-25 2026-12-26 2026-12-31] do
      assert Holidays.holiday?(Date.from_iso8601!(d)), d
    end

    refute Holidays.holiday?(~D[2026-11-20])
  end
end
