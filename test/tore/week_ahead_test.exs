defmodule Tore.WeekAheadTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Deals, WeekAhead}
  alias Tore.Agent.Job

  import Tore.FakePi

  setup :verify_on_exit!
  setup :fake_pi

  @store_url "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  # The days of the current week, so offers first seen "this week" are seen now.
  defp day(n), do: Tore.Clock.today() |> Tore.Streams.monday() |> Date.add(n - 1)
  defp at(n, time), do: NaiveDateTime.new!(day(n), time)

  # Offers running until each date in `ends`.
  defp offers(ends) do
    json =
      ends
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map_join(",", fn {valid_to, i} ->
        ~s({"details":{"name":"Vara #{i} #{valid_to}","brand":"X"},"mechanicInfo":"59 kr/kg","stores":[],"validTo":"#{valid_to}T23:59:59"})
      end)

    {:ok, ~s({"weeklyOffers":[#{json}],"compensationOffersStatus":"ok"})}
  end

  # The fetches in a test happen moments apart; real ones are a day apart.
  defp a_day_earlier do
    for d <- Repo.all(Tore.Deals.Deal) do
      d
      |> Ecto.Changeset.change(inserted_at: NaiveDateTime.add(d.inserted_at, -60))
      |> Repo.update!()
    end
  end

  defp jobs, do: Repo.all(Job, Tore.Scope.repo_opts(home_scope()))

  setup do
    {:ok, _} = Deals.add_store(home_scope(), @store_url)
    :ok
  end

  # The morning's fetch, which runs before WeekAhead (`Tore.Deals.scrape_all/0`, daily).
  defp fetched(ends) do
    expect(Tore.MockHTTP, :fetch, fn @store_url -> offers(ends) end)
    :ok = Deals.scrape_all()
  end

  test "nothing before Friday" do
    fetched(day(7))
    assert :ok = WeekAhead.run(at(4, ~T[09:00:00]))
    assert jobs() == []
  end

  test "plans once, as soon as the new week's offers are in, and never fetches itself" do
    fetched(day(7))
    # No expectations: a fetch here fails the test.
    assert :ok = WeekAhead.run(at(5, ~T[09:00:00]))
    assert jobs() == []
    a_day_earlier()

    fetched(Date.add(day(7), 7))
    assert :ok = WeekAhead.run(at(6, ~T[09:00:00]))
    assert [%Job{task: "plan_week", week: week}] = jobs()
    assert week == Date.add(day(1), 7)

    assert :ok = WeekAhead.run(at(7, ~T[09:00:00]))
    assert :ok = WeekAhead.run(at(7, ~T[18:00:00]))
    assert length(jobs()) == 1
  end

  test "a few of this week's offers running longer don't count as the new week" do
    fetched([day(7), day(7), day(7), Date.add(day(7), 14)])
    assert :ok = WeekAhead.run(at(5, ~T[09:00:00]))
    refute Deals.coming_week_in?(home_scope(), day(5))
    assert jobs() == []
  end

  test "with no new offers by Sunday evening, it plans with what there is" do
    fetched(day(7))

    assert :ok = WeekAhead.run(at(7, ~T[09:00:00]))
    assert jobs() == []

    assert :ok = WeekAhead.run(at(7, ~T[18:00:00]))
    assert [%Job{task: "plan_week"}] = jobs()
  end
end
