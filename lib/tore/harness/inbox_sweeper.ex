defmodule Tore.Harness.InboxSweeper do
  @moduledoc """
  Weekly housekeeping for the inbox surface.

  Two responsibilities, both safe to run repeatedly:

    1. **TTL expiry** — `:needs_user` runs older than `@ttl_days` get an
       explicit `RunDiscarded{reason: :ttl_expired}` event. The user
       didn't act in 14 days; we drop the inbox entry (audit row stays).

    2. **Orphan photo reap** — every key in the `tore-runs` bucket that no
       running or waiting run points at gets deleted. The post-commit
       `delete_async` is fire-and-forget, so this is the safety net for any
       S3 hiccup that leaves bytes behind. A photo stashed in the moment
       before its run opens could go too; at 04:00 on a Sunday that is a
       chance not worth more code.

  Wired as a Quantum cron entry (Sundays 04:00) — see `config :tore,
  Tore.Scheduler`. Also callable from IEx for manual sweeps.
  """

  require Logger

  import Ecto.Query

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.{Household, Repo, Scope}
  alias Tore.Storage
  alias Tore.Storage.Buckets

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
    {reaped, kept} = reap_orphan_photos(household_id)

    Logger.info(
      "InboxSweeper done: ttl_expired=#{expired}, photos_reaped=#{reaped}, photos_kept=#{kept}"
    )

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

  defp reap_orphan_photos(household_id) do
    scope = Scope.for_household(household_id)

    case Storage.client().list_object_keys(Buckets.runs(), Tore.Storage.RunPhotos.prefix(scope)) do
      {:ok, keys} ->
        in_use = photos_in_use(scope)
        {reap, keep} = Enum.split_with(keys, &(&1 not in in_use))
        Enum.each(reap, &Storage.client().delete_object(Buckets.runs(), &1))
        {length(reap), length(keep)}

      {:error, reason} ->
        Logger.warning("InboxSweeper could not list tore-runs: #{inspect(reason)}")
        {0, 0}
    end
  end

  defp photos_in_use(scope) do
    from(r in KitchenRun, where: r.status in [:running, :needs_user], select: r.input)
    |> Repo.all(Scope.repo_opts(scope))
    |> Enum.flat_map(fn input -> List.wrap(input["image_path"]) end)
    |> MapSet.new()
  end
end
