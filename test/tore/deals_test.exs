defmodule Tore.DealsTest do
  use ExUnit.Case, async: false

  import Tore.AccountsFixtures, only: [home_scope: 0, household_fixture: 0, scope_fixture: 1]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
    use_store(home_scope(), "ICA Maxi")
    :ok
  end

  # The household uses a store by that name, so its deals show.
  defp use_store(scope, name) do
    Tore.Repo.insert!(%Tore.Deals.Store{name: name, url: "https://example.test/#{name}"},
      on_conflict: :nothing
    )

    store = Tore.Repo.get_by!(Tore.Deals.Store, name: name)

    Tore.Repo.insert!(%Tore.Deals.HouseholdStore{
      household_id: scope.household_id,
      store_id: store.id
    })

    store
  end

  test "upsert_deals inserts new deals and returns count" do
    deals = [%{chain: "ica", store: "ICA Maxi", product_name: "Mjölk", source: :scraped}]
    assert {:ok, 1} = Tore.Deals.upsert_deals(deals)
  end

  test "upsert_deals inserts multiple deals" do
    deals = [
      %{chain: "ica", store: "ICA Maxi", product_name: "Bröd", source: :scraped},
      %{chain: "ica", store: "ICA Maxi", product_name: "Smör", source: :scraped}
    ]

    assert {:ok, 2} = Tore.Deals.upsert_deals(deals)
  end

  test "the same offer seen again is stored once" do
    deals = [%{chain: "ica", store: "ICA Maxi", product_name: "Ost", source: :scraped}]
    assert {:ok, 1} = Tore.Deals.upsert_deals(deals)
    assert {:ok, 0} = Tore.Deals.upsert_deals(deals)
  end

  defp deal(name, valid_until),
    do: %{chain: "ica", store: "ICA Maxi", product_name: name, valid_until: valid_until}

  defp names(deals), do: deals |> Enum.map(& &1.product_name) |> Enum.sort()

  defp stored, do: Tore.Repo.all(Tore.Deals.Deal) |> names()

  test "an offer without an end date runs to this Sunday" do
    Tore.Deals.upsert_deals([%{chain: "ica", store: "ICA Maxi", product_name: "Bröd"}])

    sunday = Tore.Clock.today() |> Tore.Streams.monday() |> Date.add(6)
    assert [%{valid_until: ^sunday}] = Tore.Repo.all(Tore.Deals.Deal)
  end

  test "list_current shows offers that haven't ended" do
    today = Tore.Clock.today()

    Tore.Deals.upsert_deals([
      deal("Fisk", Date.add(today, 7)),
      deal("Idag", today),
      deal("Igår", Date.add(today, -1))
    ])

    assert names(Tore.Deals.list_current(home_scope())) == ["Fisk", "Idag"]
  end

  test "valid_in_week leaves out offers that end before the week starts" do
    week_start = Tore.Clock.today() |> Tore.Streams.monday() |> Date.add(7)

    Tore.Deals.upsert_deals([
      deal("Söndag före", Date.add(week_start, -1)),
      deal("Måndag", week_start),
      deal("Nästa vecka", Date.add(week_start, 6))
    ])

    assert names(Tore.Deals.valid_in_week(home_scope(), week_start)) ==
             ["Måndag", "Nästa vecka"]
  end

  test "next week's offer on the same product is its own row" do
    sunday = Tore.Clock.today() |> Tore.Streams.monday() |> Date.add(6)

    assert {:ok, 1} = Tore.Deals.upsert_deals([deal("Mjölk", sunday)])
    assert {:ok, 1} = Tore.Deals.upsert_deals([deal("Mjölk", Date.add(sunday, 7))])
    assert stored() == ["Mjölk", "Mjölk"]
  end

  test "clear_expired keeps half a year of ended offers as the price history" do
    today = Tore.Clock.today()

    Tore.Deals.upsert_deals([
      deal("Förra veckan", Date.add(today, -7)),
      deal("I våras", Date.add(today, -26 * 7 + 1)),
      deal("I fjol", Date.add(today, -26 * 7 - 1))
    ])

    Tore.Deals.clear_expired()
    assert stored() == ["I våras", "Förra veckan"] |> Enum.sort()
  end

  test "a household sees deals only at the stores it uses" do
    other = scope_fixture(household_fixture())
    use_store(other, "ICA Kvantum")

    Tore.Deals.upsert_deals([
      %{chain: "ica", store: "ICA Maxi", product_name: "Mjölk", source: :scraped},
      %{chain: "ica", store: "ICA Kvantum", product_name: "Ost", source: :scraped}
    ])

    assert ["Mjölk"] = Enum.map(Tore.Deals.list_current(home_scope()), & &1.product_name)
    assert ["Ost"] = Enum.map(Tore.Deals.list_current(other), & &1.product_name)
  end
end
