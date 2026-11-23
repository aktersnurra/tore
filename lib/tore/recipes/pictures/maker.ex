defmodule Tore.Recipes.Pictures.Maker do
  @moduledoc """
  Makes the widths of recipe pictures a few at a time (`:image_resize_concurrency`, default one
  per scheduler, each vips on one thread), so a gallery's worth of first looks queues instead of
  starting a vips per tile. Asking for a width that's already being made waits for that one
  rather than making it again.

  The work itself is `fun`, run under `Tore.TaskSupervisor`; every caller waiting on it gets its
  result. A queue past `@max_queue` turns new work away with `{:error, :busy}`.
  """

  use GenServer

  @max_queue 500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs `fun` for `job` (once, however many ask at a time) and returns its result."
  @spec run(term(), (-> term()), timeout()) :: term() | {:error, :busy | :timeout}
  def run(job, fun, timeout) do
    GenServer.call(__MODULE__, {:run, job, fun}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl true
  def init(_opts) do
    max = Application.get_env(:tore, :image_resize_concurrency, System.schedulers_online())
    {:ok, %{max: max, running: %{}, waiting: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:run, job, fun}, from, state) do
    cond do
      Map.has_key?(state.waiting, job) ->
        {:noreply, update_in(state.waiting[job], &[from | &1])}

      :queue.len(state.queue) >= @max_queue ->
        {:reply, {:error, :busy}, state}

      true ->
        state = %{
          state
          | waiting: Map.put(state.waiting, job, [from]),
            queue: :queue.in({job, fun}, state.queue)
        }

        {:noreply, start_more(state)}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish(ref, result) |> start_more()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {:noreply, state |> finish(ref, {:error, {:crashed, reason}}) |> start_more()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish(state, ref, result) do
    {job, running} = Map.pop(state.running, ref)
    {callers, waiting} = Map.pop(state.waiting, job, [])
    Enum.each(callers, &GenServer.reply(&1, result))
    %{state | running: running, waiting: waiting}
  end

  defp start_more(state) do
    with true <- map_size(state.running) < state.max,
         {{:value, {job, fun}}, queue} <- :queue.out(state.queue) do
      task = Task.Supervisor.async_nolink(Tore.TaskSupervisor, fun)
      start_more(%{state | queue: queue, running: Map.put(state.running, task.ref, job)})
    else
      _ -> state
    end
  end
end
