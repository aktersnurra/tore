defmodule Tore.Harness.InboxSweeper do
  @moduledoc """
  Weekly housekeeping for the inbox surface.

  Two responsibilities, both safe to run repeatedly:

    1. **TTL expiry** — `:needs_user` runs older than `@ttl_days` get an
       explicit `RunDiscarded{reason: :ttl_expired}` event. The user
       didn't act in 14 days; we drop the inbox entry (audit row stays).

    2. **Orphan photo reap** — every key in the `tore-runs` bucket whose
       run has reached a terminal state (`Applied`, `Failed`, `Discarded`)
       gets deleted. The post-commit `delete_async` is fire-and-forget, so
       this is the safety net for any S3 hiccup that leaves bytes behind.

  Wired as a Quantum cron entry (Sundays 04:00) — see `config :tore,
  Tore.Scheduler`. Also callable from IEx for manual sweeps.
  """

  require Logger

  alias Tore.Harness.{Orchestrator, Run, Projector, ProjectorSupervisor}
  alias Tore.Harness.Run.State
  alias Tore.Household
  alias Tore.Storage
  alias Tore.Storage.Buckets

  @ttl_days 14

  @doc "Cron entry. Sweeps every household."
  @spec sweep_weekly() :: :ok
  def sweep_weekly do
    Enum.each(Household.list_ids(), &sweep/1)
  end

  @doc "Run a sweep for `household_id`. Returns :ok always."
  @spec sweep(integer()) :: :ok
  def sweep(household_id) do
    Logger.info("InboxSweeper starting for household #{household_id}")

    # Make sure the projector is up; we'll need its ETS view of pending runs.
    {:ok, _pid} = ProjectorSupervisor.start_or_lookup(household_id)

    {expired, _} = expire_stale_pending(household_id)
    {reaped, kept} = reap_orphan_photos(household_id)

    Logger.info(
      "InboxSweeper done: ttl_expired=#{expired}, photos_reaped=#{reaped}, photos_kept=#{kept}"
    )

    :ok
  end

  # ── TTL expiry ──────────────────────────────────────────────────────────

  defp expire_stale_pending(household_id) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@ttl_days, :day)

    Projector.list_pending(household_id)
    |> Enum.filter(&stale?(&1, cutoff))
    |> Enum.reduce({0, 0}, fn run, {ok_count, err_count} ->
      case Orchestrator.discard_run(Tore.Scope.for_household(household_id), run.stream_id,
             reason: :ttl_expired
           ) do
        {:ok, _} ->
          {ok_count + 1, err_count}

        {:error, reason} ->
          Logger.warning("InboxSweeper failed to discard #{run.stream_id}: #{inspect(reason)}")
          {ok_count, err_count + 1}
      end
    end)
  end

  defp stale?(%{opened_at: %DateTime{} = opened}, cutoff),
    do: DateTime.compare(opened, cutoff) == :lt

  defp stale?(%{opened_at: opened}, cutoff) when is_binary(opened) do
    case DateTime.from_iso8601(opened) do
      {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :lt
      _ -> false
    end
  end

  defp stale?(_, _), do: false

  # ── Orphan photo reap ───────────────────────────────────────────────────
  #
  # Strategy: each photo key lives under `households/<id>/<stream_id>/<uuid>.jpg`.
  # We list the household's keys, group by stream_id, look up each run's
  # state, and delete photos whose run is terminal.
  defp reap_orphan_photos(household_id) do
    prefix = Tore.Storage.RunPhotos.prefix(Tore.Scope.for_household(household_id))

    case Storage.client().list_object_keys(Buckets.runs(), prefix) do
      {:ok, keys} ->
        keys
        |> Enum.group_by(&stream_id_from_key(&1, prefix))
        |> Enum.reject(fn {sid, _} -> is_nil(sid) end)
        |> Enum.reduce({0, 0}, fn {stream_id, keys}, {reaped, kept} ->
          if reapable?(household_id, stream_id) do
            Enum.each(keys, &Storage.client().delete_object(Buckets.runs(), &1))
            {reaped + length(keys), kept}
          else
            {reaped, kept + length(keys)}
          end
        end)

      {:error, reason} ->
        Logger.warning("InboxSweeper could not list tore-runs: #{inspect(reason)}")
        {0, 0}
    end
  end

  defp stream_id_from_key(key, prefix) do
    case key |> String.replace_prefix(prefix, "") |> String.split("/", parts: 2) do
      [sid, _filename] -> sid
      _ -> nil
    end
  end

  defp reapable?(household_id, stream_id) do
    case Run.load(Tore.Scope.for_household(household_id), stream_id) do
      {:ok, %State.Applied{}} -> true
      {:ok, %State.Failed{}} -> true
      {:ok, %State.Discarded{}} -> true
      _ -> false
    end
  end
end
