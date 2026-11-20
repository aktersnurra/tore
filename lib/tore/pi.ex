defmodule Tore.Pi do
  @moduledoc """
  Tore's client for pi, the harness every AI request goes through. Tore has no model client of
  its own (image generation aside): it hands pi a prompt for a household, and pi reaches Tore
  through `/mcp` with a token for that household only (`Tore.Mcp.SessionToken`).

  A household has named sessions, each its own pi process (`Tore.Pi.Session`) and pi's own
  session of that id, kept across processes: a chat per person (`chat_session/1`), which they talk
  to and watch, a chat per person about one recipe (`recipe_chat_session/2`), which opening that
  recipe's chat again goes back to, and one per background job, so a job never lands in someone's conversation. A
  name is `<kind>-<id>`; the kind is what its cost is counted as. Everything pi writes is
  broadcast on `topic/2` as `{:pi, session, event}`, with pi's own event shapes
  (`message_update`, `tool_execution_start`, `agent_settled`, …).

  The command is `config :tore, :pi, command: [...]` (`TORE_PI_COMMAND`): `harness/pi-session`
  on this machine, or ssh to the harness machine, where a forced command runs it. A household
  needs what a model call has always needed: a sponsor and room under its monthly limit.
  """

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.{Costs, Household, Scope}
  alias Tore.Pi.Session

  @type session :: String.t()

  @monthly_limit_usd 20.0

  @doc "What one household may spend on pi in a calendar month, in USD."
  @spec monthly_limit_usd() :: float()
  def monthly_limit_usd, do: @monthly_limit_usd

  @spec configured?() :: boolean()
  def configured?, do: config()[:command] not in [nil, []]

  @doc "Whether the household may use pi now: `:ok`, or why not."
  @spec check(Scope.t()) :: :ok | {:error, :pi_off | :ai_unavailable | :budget_exceeded}
  def check(%Scope{} = scope) do
    cond do
      not configured?() ->
        {:error, :pi_off}

      Household.ai_sponsor(scope) == nil ->
        {:error, :ai_unavailable}

      Costs.llm_spend_this_month(scope) >= @monthly_limit_usd ->
        {:error, :budget_exceeded}

      true ->
        :ok
    end
  end

  @doc """
  What to tell someone whose request `check/1` refused, also when a run wrapped the refusal as
  `{:step_failed, reason}`. Nil for any other error, so the caller keeps its own message.
  """
  @spec refusal_text(term()) :: String.t() | nil
  def refusal_text({:step_failed, reason}), do: refusal_text(reason)

  def refusal_text(:ai_unavailable), do: gettext("AI is off for this household.")

  def refusal_text(:budget_exceeded),
    do: gettext("This household has used its AI budget for this month.")

  def refusal_text(_reason), do: nil

  @doc "The signed-in person's chat with pi."
  @spec chat_session(Scope.t()) :: session()
  def chat_session(%Scope{user_id: user_id}) when is_integer(user_id), do: "chat-#{user_id}"

  @doc "The signed-in person's chat with pi about one recipe. Its cost counts as their chat's."
  @spec recipe_chat_session(Scope.t(), pos_integer()) :: session()
  def recipe_chat_session(%Scope{} = scope, recipe_id) when is_integer(recipe_id),
    do: "#{chat_session(scope)}-recipe-#{recipe_id}"

  @spec topic(Scope.t(), session()) :: String.t()
  def topic(%Scope{household_id: id}, session), do: "pi:#{id}:#{session}"

  @spec subscribe(Scope.t(), session()) :: :ok | {:error, term()}
  def subscribe(%Scope{} = scope, session),
    do: Phoenix.PubSub.subscribe(Tore.PubSub, topic(scope, session))

  @doc """
  Sends `message` to the household's session, starting it if it isn't running. Returns at once;
  the answer arrives on the topic. `:images` is a list of `{mime_type, bytes}`. A message sent
  while the session is working waits until it is done.
  """
  @spec ask(Scope.t(), session(), String.t(), keyword()) :: :ok | {:error, atom()}
  def ask(%Scope{} = scope, session, message, opts \\ []) do
    with :ok <- check(scope),
         {:ok, pid} <- ensure_started(scope, session) do
      prompt(pid, message, Keyword.get(opts, :images, []))
    end
  end

  # A pi that exits as it starts ends its session before the session takes the prompt.
  defp prompt(pid, message, images) do
    GenServer.call(pid, {:prompt, message, images})
  catch
    :exit, _ -> {:error, :exited}
  end

  @doc """
  The session's conversation so far, as pi keeps it (`user`, `assistant` and `toolResult`
  messages, in pi's shapes). Starts the session's process to ask, which costs no model call.
  """
  @spec messages(Scope.t(), session()) :: {:ok, [map()]} | {:error, term()}
  def messages(%Scope{} = scope, session) do
    with true <- configured?() || {:error, :pi_off},
         {:ok, pid} <- ensure_started(scope, session),
         {:ok, %{"messages" => messages}} <- command(pid, %{type: "get_messages"}) do
      {:ok, messages}
    end
  end

  # pi takes a moment to start, so a command waits longer than a GenServer call does by default.
  defp command(pid, command) do
    GenServer.call(pid, {:command, command}, :timer.seconds(20))
  catch
    :exit, _ -> {:error, :pi_unavailable}
  end

  @doc "Stops what the session is doing now."
  @spec abort(Scope.t(), session()) :: :ok
  def abort(%Scope{} = scope, session) do
    case GenServer.whereis(Session.via(scope, session)) do
      nil -> :ok
      pid -> GenServer.call(pid, :abort)
    end
  end

  @doc """
  Sends `message` and waits until pi is done with it, for background work. Answers pi's last
  assistant text and what the run cost. The session ends with the run.
  """
  @spec run(Scope.t(), session(), String.t(), keyword()) ::
          {:ok, %{text: String.t() | nil, cost_usd: float()}} | {:error, atom()}
  def run(%Scope{} = scope, session, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(15))
    :ok = subscribe(scope, session)

    try do
      with :ok <- ask(scope, session, message, opts) do
        result = collect(session, %{text: nil, cost_usd: 0.0}, deadline(timeout))
        stop(scope, session)
        result
      end
    after
      Phoenix.PubSub.unsubscribe(Tore.PubSub, topic(scope, session))
    end
  end

  defp collect(session, acc, deadline) do
    receive do
      {:pi, ^session, %{"type" => "message_end", "message" => %{"role" => "assistant"} = message}} ->
        acc = %{
          text: assistant_text(message) || acc.text,
          cost_usd: acc.cost_usd + (get_in(message, ["usage", "cost", "total"]) || 0) / 1
        }

        collect(session, acc, deadline)

      {:pi, ^session, %{"type" => "agent_settled"}} ->
        {:ok, acc}

      {:pi, ^session, %{"type" => "exited"}} ->
        {:error, :exited}

      {:pi, ^session, _event} ->
        collect(session, acc, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @doc "The text of an assistant message as pi writes it, or nil when it has none."
  @spec assistant_text(map()) :: String.t() | nil
  def assistant_text(%{"content" => content}) when is_list(content) do
    case for(%{"type" => "text", "text" => text} <- content, do: text) do
      [] -> nil
      texts -> Enum.join(texts, "\n")
    end
  end

  def assistant_text(_message), do: nil

  defp stop(scope, session) do
    case GenServer.whereis(Session.via(scope, session)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Tore.Pi.Sessions, pid)
    end
  end

  defp ensure_started(scope, session) do
    case DynamicSupervisor.start_child(Tore.Pi.Sessions, {Session, {scope, session}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} -> {:error, :pi_unavailable}
    end
  end

  @doc false
  def config, do: Application.get_env(:tore, :pi, [])
end
