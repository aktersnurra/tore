defmodule Tore.Pi.Session do
  @moduledoc """
  One pi process in RPC mode for one household session, such as its chat or one background job.
  It starts the configured command (`harness/pi-session`, or ssh to the harness machine), writes
  the header with a fresh session token, then pi's RPC commands, and broadcasts every record pi
  writes to `Tore.Pi.topic/2` as `{:pi, session, event}`.

  When a run settles, what its assistant messages cost goes into `llm_usage` as `pi_<kind>`, the
  session name up to its first `-` (`chat-7` is `pi_chat`), so the household's monthly limit
  sees it. An idle session stops after a while, and a session whose token is getting old is
  started afresh before its next prompt.

  A command with an answer (`get_messages`) goes with an id; pi's response with that id is the
  caller's reply, and every other record is broadcast.
  """
  use GenServer, restart: :temporary

  alias Tore.{Costs, Scope}
  alias Tore.Mcp.SessionToken

  require Logger

  @idle_ms :timer.minutes(15)
  @token_s 2 * 60 * 60
  # A session older than this is started again before a prompt, so its token can't run out
  # mid-run.
  @renew_s 90 * 60
  @max_line 4 * 1024 * 1024

  def start_link({%Scope{} = scope, name}),
    do: GenServer.start_link(__MODULE__, {scope, name}, name: via(scope, name))

  def via(%Scope{household_id: id}, name), do: {:via, Registry, {Tore.Pi.Registry, {id, name}}}

  @impl true
  def init({scope, name}) do
    state = %{
      scope: scope,
      name: name,
      cost: 0.0,
      busy: false,
      buffer: "",
      idle: nil,
      pending: %{},
      next_id: 1
    }

    {:ok, state |> open() |> schedule_idle()}
  end

  @impl true
  def handle_call({:prompt, message, images}, _from, state) do
    state = if not state.busy and age_s(state) > @renew_s, do: reopen(state), else: state

    command =
      %{type: "prompt", message: message}
      |> put_images(images)
      |> then(&if state.busy, do: Map.put(&1, :streamingBehavior, "followUp"), else: &1)

    send_record(state, command)
    {:reply, :ok, %{state | busy: true} |> cancel_idle()}
  end

  def handle_call(:abort, _from, state) do
    send_record(state, %{type: "abort"})
    {:reply, :ok, state}
  end

  def handle_call({:command, command}, from, state) do
    id = "tore-#{state.next_id}"
    send_record(state, Map.put(command, :id, id))

    {:noreply,
     %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    record = state.buffer <> line
    state = %{state | buffer: ""}

    case Jason.decode(record) do
      {:ok, event} -> {:noreply, handle_event(event, state)}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("pi_session_exit household=#{state.scope.household_id} status=#{status}")
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :exited})
    broadcast(state, %{"type" => "exited", "status" => status})
    {:stop, :normal, state}
  end

  def handle_info(:idle, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp handle_event(%{"type" => "response", "id" => id} = response, state)
       when is_map_key(state.pending, id) do
    {from, pending} = Map.pop!(state.pending, id)

    GenServer.reply(
      from,
      if(response["success"], do: {:ok, response["data"]}, else: {:error, response["error"]})
    )

    %{state | pending: pending}
  end

  defp handle_event(%{"type" => "message_end", "message" => %{"role" => "assistant"} = m}, state) do
    broadcast(state, %{"type" => "message_end", "message" => m})
    %{state | cost: state.cost + (get_in(m, ["usage", "cost", "total"]) || 0)}
  end

  defp handle_event(%{"type" => "agent_settled"} = event, state) do
    record_cost(state)
    broadcast(state, event)
    %{state | busy: false, cost: 0.0} |> schedule_idle()
  end

  defp handle_event(event, state) do
    broadcast(state, event)
    state
  end

  defp record_cost(%{cost: cost}) when cost <= 0, do: :ok

  defp record_cost(state) do
    {:ok, _} =
      Costs.log_llm_usage(state.scope, %{
        feature: "pi_" <> (state.name |> String.split("-") |> hd()),
        cost_usd: state.cost / 1
      })

    :ok
  end

  defp open(state) do
    config = Tore.Pi.config()
    [command | args] = config[:command]

    port =
      Port.open({:spawn_executable, System.find_executable(command) || command}, [
        :binary,
        :exit_status,
        {:line, @max_line},
        args: args
      ])

    header = %{
      household: state.scope.household_id,
      session: state.name,
      mcp_url: config[:mcp_url] || ToreWeb.Endpoint.url() <> "/mcp",
      token: SessionToken.mint(state.scope.household_id, "pi-#{state.name}", @token_s),
      model: config[:model]
    }

    Port.command(port, Jason.encode!(header) <> "\n")
    Map.merge(state, %{port: port, opened_at: System.monotonic_time(:second)})
  end

  defp reopen(state) do
    Port.close(state.port)
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :exited})
    open(%{state | buffer: "", pending: %{}})
  end

  defp age_s(state), do: System.monotonic_time(:second) - state.opened_at

  defp send_record(state, record), do: Port.command(state.port, Jason.encode!(record) <> "\n")

  defp put_images(command, []), do: command

  defp put_images(command, images) do
    Map.put(
      command,
      :images,
      for({mime, data} <- images, do: %{type: "image", mimeType: mime, data: Base.encode64(data)})
    )
  end

  defp broadcast(state, event),
    do:
      Phoenix.PubSub.broadcast(
        Tore.PubSub,
        Tore.Pi.topic(state.scope, state.name),
        {:pi, state.name, event}
      )

  defp schedule_idle(state),
    do: %{cancel_idle(state) | idle: Process.send_after(self(), :idle, @idle_ms)}

  defp cancel_idle(%{idle: nil} = state), do: state

  defp cancel_idle(%{idle: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle: nil}
  end
end
