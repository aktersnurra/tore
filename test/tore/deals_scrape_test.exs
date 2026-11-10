defmodule Tore.DealsScrapeTest do
  use ExUnit.Case, async: false

  import Mox
  setup :verify_on_exit!

  import Tore.AccountsFixtures, only: [home_scope: 0, household_fixture: 0, scope_fixture: 1]

  alias Tore.Deals

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  @ica_html ~s({"weeklyOffers":[{"details":{"name":"Kycklingfilé","brand":"Kronfågel"},"parsedMechanics":{"value1":"1","value2":"59","value4":"/kg"},"stores":[{"storeMarketingName":"ICA Maxi","regularPrice":"89"}],"comparisonPrice":null,"validTo":null}],"compensationOffersStatus":"ok"})

  @store_url "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  test "scrape_url fetches HTML, parses deals, and upserts under the store's name and chain" do
    Tore.MockHTTP
    |> expect(:fetch, fn @store_url -> {:ok, @ica_html} end)

    assert {:ok, 1} = Tore.Deals.scrape_url(@store_url, "Danvikstull")

    deal = Tore.Repo.get_by!(Tore.Deals.Deal, product_name: "Kycklingfilé")
    assert deal.store == "Danvikstull"
    assert deal.chain == "ica"
  end

  test "scrape_url returns error on HTTP failure" do
    Tore.MockHTTP
    |> expect(:fetch, fn _url -> {:error, :timeout} end)

    assert {:error, :timeout} = Tore.Deals.scrape_url(@store_url, "Danvikstull")
  end

  test "scrape_url never fetches a link no backend handles" do
    # No MockHTTP expectation: any fetch here fails the test.
    assert {:error, :unsupported_store} =
             Tore.Deals.scrape_url("https://evil.example/erbjudanden/", "Evil")
  end

  test "scrape_all returns :ok with no enabled store configs" do
    assert :ok = Tore.Deals.scrape_all()
  end

  describe "stores" do
    test "add_store takes only a link and starts switched on" do
      assert {:ok, entry} = Deals.add_store(home_scope(), "  #{@store_url}\n")

      assert entry.store.url == @store_url
      assert entry.store.name == "ICA Supermarket Danvikstull"
      assert entry.scrape_enabled
    end

    test "add_store refuses links no backend can read" do
      assert {:error, :unsupported_store} =
               Deals.add_store(home_scope(), "https://www.coop.se/x/")

      assert {:error, :unsupported_store} = Deals.add_store(home_scope(), "http://www.ica.se/x/")

      assert {:error, :unsupported_store} =
               Deals.add_store(home_scope(), "https://www.ica.se/recept/")

      assert Deals.list_stores(home_scope()) == []
    end

    test "add_store refuses the same link twice in one household" do
      assert {:ok, _} = Deals.add_store(home_scope(), @store_url)
      assert {:error, %Ecto.Changeset{}} = Deals.add_store(home_scope(), @store_url)
    end

    test "scrape_all skips stores switched off" do
      {:ok, entry} = Deals.add_store(home_scope(), @store_url)
      {:ok, _} = Deals.toggle_scraping(home_scope(), entry.id)

      # No MockHTTP expectation: fetching a switched-off store fails the test.
      assert :ok = Deals.scrape_all()
    end

    test "scrape_all fetches stores switched on" do
      {:ok, _} = Deals.add_store(home_scope(), @store_url)

      Tore.MockHTTP
      |> expect(:fetch, fn @store_url -> {:ok, @ica_html} end)

      assert :ok = Deals.scrape_all()

      assert Enum.any?(
               Deals.list_current(home_scope()),
               &(&1.store == "ICA Supermarket Danvikstull")
             )
    end

    test "two households on one store share it: one fetch, and both see its deals" do
      other = scope_fixture(household_fixture())
      neither = scope_fixture(household_fixture())
      {:ok, mine} = Deals.add_store(home_scope(), @store_url)
      {:ok, theirs} = Deals.add_store(other, @store_url)
      assert mine.store_id == theirs.store_id

      Tore.MockHTTP
      |> expect(:fetch, 1, fn @store_url -> {:ok, @ica_html} end)

      assert :ok = Deals.scrape_all()

      assert [%{product_name: "Kycklingfilé"}] = Deals.list_current(home_scope())
      assert [%{product_name: "Kycklingfilé"}] = Deals.list_current(other)
      assert Deals.list_current(neither) == []
    end

    test "different links to one store are the same store" do
      other = scope_fixture(household_fixture())
      {:ok, mine} = Deals.add_store(home_scope(), @store_url)

      {:ok, theirs} =
        Deals.add_store(
          other,
          "https://ica.se/erbjudanden/ica-supermarket-danvikstull-1156002?utm=x"
        )

      assert theirs.store_id == mine.store_id
      assert theirs.store.url == @store_url
    end

    test "a store switched off in one household is still fetched for another, and hidden only where off" do
      other = scope_fixture(household_fixture())
      {:ok, mine} = Deals.add_store(home_scope(), @store_url)
      {:ok, _} = Deals.add_store(other, @store_url)
      {:ok, _} = Deals.toggle_scraping(home_scope(), mine.id)

      Tore.MockHTTP
      |> expect(:fetch, 1, fn @store_url -> {:ok, @ica_html} end)

      assert :ok = Deals.scrape_all()
      assert Deals.list_current(home_scope()) == []
      assert [%{product_name: "Kycklingfilé"}] = Deals.list_current(other)
    end

    test "a household's store list, switches and removal are its own" do
      other = scope_fixture(household_fixture())
      {:ok, mine} = Deals.add_store(home_scope(), @store_url)
      {:ok, theirs} = Deals.add_store(other, @store_url)

      {:ok, _} = Deals.toggle_scraping(home_scope(), mine.id)
      {:ok, _} = Deals.remove_store(home_scope(), mine.id)

      assert Deals.list_stores(home_scope()) == []
      assert [%{id: id, scrape_enabled: true}] = Deals.list_stores(other)
      assert id == theirs.id
      assert {:error, :not_found} = Deals.toggle_scraping(home_scope(), theirs.id)
      assert {:error, :not_found} = Deals.remove_store(home_scope(), theirs.id)
    end
  end

  test "no scheduled job generates prep guides" do
    jobs = Application.fetch_env!(:tore, Tore.Scheduler)[:jobs]

    assert Enum.any?(jobs, &match?({_, {Tore.Deals, :scrape_all, []}}, &1))
    refute Enum.any?(jobs, &match?({_, {Tore.Prep, _, _}}, &1))
    # A job given as a closure can't be inspected, which is how this one hid.
    assert Enum.all?(jobs, &match?({_, {_, _, _}}, &1))
  end
end
