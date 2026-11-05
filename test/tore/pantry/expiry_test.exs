defmodule Tore.Pantry.ExpiryTest do
  use ExUnit.Case, async: true

  alias Tore.Pantry.Expiry

  @today ~D[2026-11-05]
  @none %{expires_at: nil, expires_source: nil}
  @photo %{provenance: "vision"}
  @tick %{provenance: "grocery_checkoff"}

  defp dated(source), do: %{expires_at: ~D[2026-11-07], expires_source: source}

  test "a printed date is used" do
    observed = Map.put(@photo, :expires_on, ~D[2026-12-01])
    assert Expiry.next(@none, observed, 7, @today) == {~D[2026-12-01], "label"}
  end

  test "a printed date replaces a guess" do
    observed = Map.put(@photo, :expires_on, ~D[2026-12-01])
    assert Expiry.next(dated("estimate"), observed, 7, @today) == {~D[2026-12-01], "label"}
  end

  test "buying starts from today and the shelf life" do
    assert Expiry.next(@none, @tick, 7, @today) == {~D[2026-11-12], "estimate"}
  end

  test "buying replaces any earlier date, even one the household set" do
    assert Expiry.next(dated("manual"), @tick, 7, @today) == {~D[2026-11-12], "estimate"}
    assert Expiry.next(dated("label"), @tick, 7, @today) == {~D[2026-11-12], "estimate"}
  end

  test "buying with no known shelf life clears the old date" do
    assert Expiry.next(dated("estimate"), @tick, nil, @today) == {nil, nil}
  end

  test "a photo of an item with no date estimates one" do
    assert Expiry.next(@none, @photo, 7, @today) == {~D[2026-11-12], "estimate"}
  end

  test "a photo never extends a date" do
    assert Expiry.next(dated("estimate"), @photo, 30, @today) == {~D[2026-11-07], "estimate"}
    assert Expiry.next(dated("label"), @photo, 30, @today) == {~D[2026-11-07], "label"}
  end

  test "a date the household set beats a printed one" do
    observed = Map.put(@photo, :expires_on, ~D[2026-12-01])
    assert Expiry.next(dated("manual"), observed, 7, @today) == {~D[2026-11-07], "manual"}
  end

  test "with no shelf life and no date, there's no date" do
    assert Expiry.next(@none, @photo, nil, @today) == {nil, nil}
  end

  test "a shelf life outside what food could keep is dropped" do
    assert Expiry.parse_shelf_life(7) == 7
    assert Expiry.parse_shelf_life(3650) == 3650
    assert Expiry.parse_shelf_life(0) == nil
    assert Expiry.parse_shelf_life(-3) == nil
    assert Expiry.parse_shelf_life(3651) == nil
    assert Expiry.parse_shelf_life("7") == nil
    assert Expiry.parse_shelf_life(nil) == nil
  end

  test "a date that can't be read is dropped" do
    assert Expiry.parse_date("2026-12-01") == ~D[2026-12-01]
    assert Expiry.parse_date("12/01") == nil
    assert Expiry.parse_date(nil) == nil
  end
end
