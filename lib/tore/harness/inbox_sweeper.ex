defmodule Tore.Harness.InboxSweeper do
  @moduledoc """
  Weekly housekeeping for runs that wait on the person.

  `:needs_user` runs opened more than `@ttl_days` ago are discarded through
  `Runs.discard/3` with reason `:ttl_expired`. Nobody answered in 14 days and
  nothing was applied; the run row stays, as `:discarded`. Safe to run repeatedly.

  Wired as a Quantum cron entry (Sundays 04:00) — see `config :tore,
  Tore.Scheduler`. Also callable from IEx for manual sweeps.
  """

  require Logger

  alias Tore.Harness.Runs
  alias Tore.{Household, Scope}

  @ttl_days 14

  @doc "Cron entry. Sweeps every household."
  @spec sweep_weekly() :: :ok
  def sweep_weekly do
    Household.each_scope(&sweep(&1.household_id))
  end

  @doc "Run a sweep for `household_id`. Returns :ok always."
  @spec sweep(integer()) :: :ok
  def sweep(household_id) do
    Logger.info("InboxSweeper starting for household #{household_id}")

    {expired, _} = expire_stale_pending(household_id)

    Logger.info("InboxSweeper done: ttl_expired=#{expired}")

    :ok
  end

  # ── TTL expiry ──────────────────────────────────────────────────────────

  defp expire_stale_pending(household_id) do
    scope = Scope.for_household(household_id)
    cutoff = DateTime.utc_now() |> DateTime.add(-@ttl_days, :day)

    Runs.list_pending(scope)
    |> Enum.filter(&(DateTime.compare(&1.opened_at, cutoff) == :lt))
    |> Enum.reduce({0, 0}, fn run, {ok_count, err_count} ->
      case Runs.discard(scope, run.id, :ttl_expired) do
        {:ok, _} ->
          {ok_count + 1, err_count}

        {:error, reason} ->
          Logger.warning("InboxSweeper failed to discard #{run.id}: #{inspect(reason)}")
          {ok_count, err_count + 1}
      end
    end)
  end
end
