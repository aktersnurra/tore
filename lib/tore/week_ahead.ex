defmodule Tore.WeekAhead do
  @moduledoc """
  Gets the coming week ready: its offers, then its plan. Runs on Friday, Saturday and Sunday
  mornings, and at the Sunday deadline.

  Each morning run fetches the stores whose offers for the coming week haven't appeared yet
  (`Tore.Deals.scrape_all/1`), so a store is fetched at most once a day and not again once its new
  offers are in. The deadline run doesn't fetch. A household that can use the server's model gets its coming week planned once
  (`Tore.Planning.plan_upcoming_week/2`): as soon as all its stores' new offers are in, or at the
  Sunday deadline with whatever prices there are. Offers arriving after that change the estimate
  and the alternatives, never the plan.
  """

  import Ecto.Query

  alias Tore.{Deals, Household, Planning, Repo, Scope, Streams}
  alias Tore.Harness.KitchenRun

  @from_weekday 5
  @deadline ~T[18:00:00]

  @spec run(NaiveDateTime.t()) :: :ok
  def run(%NaiveDateTime{} = now \\ Tore.Clock.now()) do
    today = NaiveDateTime.to_date(now)

    if Date.day_of_week(today) >= @from_weekday do
      deadline? =
        Date.day_of_week(today) == 7 and
          Time.compare(NaiveDateTime.to_time(now), @deadline) != :lt

      # The deadline run plans with what the morning fetched: once a day per store, at most.
      unless deadline?, do: :ok = Deals.scrape_all(today)

      Household.each_scope(fn scope ->
        if Tore.LLM.check(scope) == :ok and not planned?(scope, today) and
             (deadline? or Deals.coming_week_in?(scope, today)),
           do: Planning.plan_upcoming_week(scope, today)
      end)
    end

    :ok
  end

  # A weekly plan for the coming week has run, or is running. A failed one is tried again.
  defp planned?(scope, today) do
    week = today |> Streams.monday() |> Date.add(7) |> Date.to_iso8601()

    from(r in KitchenRun,
      where:
        r.kind == "weekly_planning_run" and r.status != :failed and
          fragment("json_extract(?, '$.week_start')", r.input) == ^week
    )
    |> Repo.exists?(Scope.repo_opts(scope))
  end
end
