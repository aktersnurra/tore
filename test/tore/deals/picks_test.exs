defmodule Tore.Deals.PicksTest do
  use Tore.DataCase, async: false

  alias Tore.{Costs, Deals, Recipes, Streams}
  alias Tore.Deals.Picks

  setup do
    store = Repo.insert!(%Deals.Store{name: "ICA Maxi", url: "https://example.test/maxi"})

    Repo.insert!(%Deals.HouseholdStore{
      household_id: home_scope().household_id,
      store_id: store.id
    })

    {:ok, _} =
      Deals.upsert_deals(
        for name <- ["Laxfilé", "Fläskkarré", "Kattmat", "Glass"] do
          %{
            chain: "ica",
            store: "ICA Maxi",
            product_name: name,
            price: Decimal.new(49),
            valid_until: Date.add(Tore.Clock.today(), 2)
          }
        end
      )

    {:ok, _} = Recipes.create(home_scope(), %{title: "Laxpasta", base_servings: 4})
    :ok
  end

  defp req, do: Req.new(plug: {Req.Test, __MODULE__})

  # Jev, as the household would have it: they buy salmon, ice cream maybe, no pork, surely no cat
  # food. Each call is told to the test.
  defp jev do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"state" => state, "questions" => questions} = Jason.decode!(body)
      send(test, {:asked, state, questions})

      answers =
        Map.new(questions, fn {key, %{"instructions" => text}} ->
          {choice, confidence} =
            cond do
              text =~ "Laxfilé" -> {"usual", 0.8}
              text =~ "Glass" -> {"maybe", 0.6}
              text =~ "Fläskkarré" -> {"no", 0.4}
              true -> {"no", 0.9}
            end

          {key, %{"choice" => choice, "confidence" => confidence}}
        end)

      Req.Test.json(conn, %{"answers" => answers, "usage" => %{"cost" => 0.0001}})
    end)
  end

  defp by_name(picks) do
    names = Map.new(Deals.list_current(home_scope()), &{&1.id, &1.product_name})
    Map.new(picks, fn {id, pick} -> {names[id], pick} end)
  end

  test "Jev sorts each offer as something they buy, might want or wouldn't, from what Tore knows" do
    jev()

    assert {:ok, 4} = Picks.sort(home_scope(), req: req(), api_key: "k")
    assert_received {:asked, state, questions}
    assert Enum.any?(state, &(&1 =~ "Laxpasta"))

    assert Enum.all?(questions, fn {_key, q} ->
             q["type"] == "choice" and Map.keys(q["criteria"]) == ["maybe", "no", "usual"]
           end)

    assert by_name(Picks.all(home_scope())) == %{
             "Laxfilé" => {:usual, 0.8},
             "Glass" => {:maybe, 0.6},
             "Fläskkarré" => {:no, 0.4},
             "Kattmat" => {:no, 0.9}
           }

    assert Costs.last_llm_call(home_scope(), "deal_picks")
  end

  test "an offer is asked about once" do
    jev()
    {:ok, 4} = Picks.sort(home_scope(), req: req(), api_key: "k")
    assert_received {:asked, _, _}

    assert {:ok, 0} = Picks.sort(home_scope(), req: req(), api_key: "k")
    refute_received {:asked, _, _}
  end

  test "a household without AI isn't asked about" do
    jev()
    unsponsored = scope_fixture(household_fixture())
    assert {:error, :ai_unavailable} = Picks.sort(unsponsored, req: req(), api_key: "k")
    refute_received {:asked, _, _}
  end

  test "on Erbjudanden, Jev's answers sort the offers; only a sure no is folded away" do
    jev()
    {:ok, 4} = Picks.sort(home_scope(), req: req(), api_key: "k")

    today = Tore.Clock.today()
    page = Deals.page(home_scope(), Streams.monday(today), today)

    assert Enum.map(page.usual, & &1.name) == ["Laxfilé"]
    assert Enum.map(page.maybe, & &1.name) == ["Glass"]
    assert Enum.map(page.others, & &1.name) == ["Fläskkarré"]
    assert Enum.map(page.not_for_us, & &1.name) == ["Kattmat"]
  end
end
