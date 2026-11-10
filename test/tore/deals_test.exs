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

  test "upsert_deals is idempotent via on_conflict: :nothing" do
    deals = [%{chain: "ica", store: "ICA Maxi", product_name: "Ost", source: :scraped}]
    assert {:ok, 1} = Tore.Deals.upsert_deals(deals)
    assert {:ok, 0} = Tore.Deals.upsert_deals(deals)
  end

  test "list_current returns deals without valid_until" do
    Tore.Deals.upsert_deals([
      %{chain: "ica", store: "ICA Maxi", product_name: "Bröd", source: :scraped}
    ])

    deals = Tore.Deals.list_current(home_scope())
    assert Enum.any?(deals, &(&1.product_name == "Bröd"))
  end

  test "list_current returns deals with future valid_until" do
    future = Date.add(Tore.Clock.today(), 7)

    Tore.Deals.upsert_deals([
      %{
        chain: "ica",
        store: "ICA Maxi",
        product_name: "Fisk",
        source: :scraped,
        valid_until: future
      }
    ])

    deals = Tore.Deals.list_current(home_scope())
    assert Enum.any?(deals, &(&1.product_name == "Fisk"))
  end

  test "list_current excludes expired deals" do
    Tore.Deals.upsert_deals([
      %{
        chain: "ica",
        store: "ICA Maxi",
        product_name: "Expired",
        source: :scraped,
        valid_until: ~D[2020-01-01]
      }
    ])

    deals = Tore.Deals.list_current(home_scope())
    refute Enum.any?(deals, &(&1.product_name == "Expired"))
  end

  test "clear_expired removes deals past valid_until" do
    Tore.Deals.upsert_deals([
      %{
        chain: "ica",
        store: "ICA Maxi",
        product_name: "OldDeal",
        source: :scraped,
        valid_until: ~D[2020-01-01]
      }
    ])

    Tore.Deals.clear_expired()
    deals = Tore.Deals.list_current(home_scope())
    refute Enum.any?(deals, &(&1.product_name == "OldDeal"))
  end

  test "clear_expired keeps current deals" do
    Tore.Deals.upsert_deals([
      %{chain: "ica", store: "ICA Maxi", product_name: "Current", source: :scraped}
    ])

    Tore.Deals.clear_expired()
    deals = Tore.Deals.list_current(home_scope())
    assert Enum.any?(deals, &(&1.product_name == "Current"))
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
