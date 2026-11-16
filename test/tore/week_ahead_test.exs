defmodule Tore.WeekAheadTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Deals, WeekAhead}
  alias Tore.Harness.KitchenRun

  setup :verify_on_exit!

  @store_url "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  # The days of the current week, so offers first seen "this week" are seen now.
  defp day(n), do: Tore.Clock.today() |> Tore.Streams.monday() |> Date.add(n - 1)
  defp at(n, time), do: NaiveDateTime.new!(day(n), time)

  # One offer, running until `valid_to`.
  defp offers(valid_to) do
    {:ok,
     ~s({"weeklyOffers":[{"details":{"name":"Kycklingfilé #{valid_to}","brand":"Kronfågel"},"mechanicInfo":"59 kr/kg","stores":[],"validTo":"#{valid_to}T23:59:59"}],"compensationOffersStatus":"ok"})}
  end

  defp plans_once do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Nothing to do."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)
  end

  defp runs, do: Repo.all(KitchenRun, Tore.Scope.repo_opts(home_scope()))

  setup do
    {:ok, _} = Deals.add_store(home_scope(), @store_url)
    :ok
  end

  test "nothing before Friday" do
    # No expectations: a fetch or a model call fails the test.
    assert :ok = WeekAhead.run(at(4, ~T[09:00:00]))
    assert runs() == []
  end

  test "fetches daily until the new week's offers are in, then plans once and stops fetching" do
    expect(Tore.MockHTTP, :fetch, fn @store_url -> offers(day(7)) end)
    assert :ok = WeekAhead.run(at(5, ~T[09:00:00]))
    assert runs() == []

    expect(Tore.MockHTTP, :fetch, fn @store_url -> offers(Date.add(day(7), 7)) end)
    plans_once()
    assert :ok = WeekAhead.run(at(6, ~T[09:00:00]))
    assert [%{kind: "weekly_planning_run", input: %{"week_start" => week}}] = runs()
    assert week == Date.to_iso8601(Date.add(day(1), 7))

    # Sunday: no fetch and no second plan.
    assert :ok = WeekAhead.run(at(7, ~T[09:00:00]))
    assert :ok = WeekAhead.run(at(7, ~T[18:00:00]))
    assert length(runs()) == 1
  end

  test "with no new offers by Sunday evening, it plans with what there is" do
    stub(Tore.MockHTTP, :fetch, fn @store_url -> offers(day(7)) end)

    assert :ok = WeekAhead.run(at(7, ~T[09:00:00]))
    assert runs() == []

    plans_once()
    assert :ok = WeekAhead.run(at(7, ~T[18:00:00]))
    assert [%{kind: "weekly_planning_run"}] = runs()
  end
end
