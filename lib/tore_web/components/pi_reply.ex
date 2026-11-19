defmodule ToreWeb.PiReply do
  @moduledoc """
  A screen asking pi something and showing what it says: a working line while pi works, then its
  words in a note that can be closed. What is asked goes in the person's own chat
  (`Tore.Pi.chat_session/1`), so the chat tray shows it too, and pi's changes reach the screen
  the way any change does.

  The screen calls `init/1` in mount, `ask/3` to ask, hands `{:pi, _, event}` messages to
  `event/2` and its `"dismiss_pi_reply"` event to `dismiss/1`, and renders `pi_reply/1` with
  `reply={@pi_reply} working={@pi_working}`.
  """
  use ToreWeb, :html

  alias Tore.Pi

  @doc "Starts the screen with nothing asked, listening to the person's chat once connected."
  def init(socket) do
    if Phoenix.LiveView.connected?(socket) do
      scope = socket.assigns.current_scope
      Pi.subscribe(scope, Pi.chat_session(scope))
    end

    Phoenix.Component.assign(socket, pi_reply: nil, pi_working: nil)
  end

  @doc """
  Asks pi `message`; `working` names what it's doing until it is done. `opts` go to `Tore.Pi.ask/4`
  (`:images`).
  """
  def ask(socket, message, working, opts \\ []) do
    scope = socket.assigns.current_scope

    case Pi.ask(scope, Pi.chat_session(scope), message, opts) do
      :ok ->
        Phoenix.Component.assign(socket, pi_reply: "", pi_working: working)

      {:error, reason} ->
        Phoenix.LiveView.put_flash(socket, :error, refusal(reason))
    end
  end

  @doc "The note closed."
  def dismiss(socket), do: Phoenix.Component.assign(socket, pi_reply: nil)

  @doc """
  One of pi's events. Heard only while it answers something asked from this screen; what it says
  now shows, and at the end its last words.
  """
  def event(%{assigns: %{pi_reply: nil}} = socket, _event), do: socket

  def event(
        socket,
        %{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta"} = e}
      ),
      do: Phoenix.Component.update(socket, :pi_reply, &(&1 <> e["delta"]))

  def event(socket, %{"type" => "message_start", "message" => %{"role" => "assistant"}}),
    do: Phoenix.Component.assign(socket, pi_reply: "")

  def event(socket, %{"type" => "message_end", "message" => %{"role" => "assistant"} = m}),
    do:
      Phoenix.Component.assign(socket, pi_reply: Pi.assistant_text(m) || socket.assigns.pi_reply)

  def event(socket, %{"type" => "agent_settled"}),
    do: Phoenix.Component.assign(socket, pi_working: nil)

  def event(socket, %{"type" => "exited"}) do
    socket
    |> Phoenix.LiveView.put_flash(:error, refusal(:exited))
    |> Phoenix.Component.assign(pi_reply: nil, pi_working: nil)
  end

  def event(socket, _event), do: socket

  defp refusal(reason),
    do:
      Tore.LLM.refusal_text(reason) ||
        gettext("Tore couldn't finish that. Try again in a moment.")

  attr :reply, :string, default: nil
  attr :working, :string, default: nil

  def pi_reply(assigns) do
    ~H"""
    <p
      :if={@working}
      data-role="pi-working"
      class="mt-4 flex items-center gap-2 text-[14px] text-[color:var(--muted)]"
      role="status"
    >
      <.icon name="ph-arrows-clockwise" class="size-4 motion-safe:animate-spin" />
      {@working}
    </p>
    <div
      :if={@reply not in [nil, ""]}
      data-role="pi-reply"
      class="mt-4 flex items-start gap-3 rounded-2xl bg-[var(--sunken)] px-4 py-3"
      aria-live="polite"
    >
      <p class="min-w-0 flex-1 whitespace-pre-line text-[15px] leading-snug">{@reply}</p>
      <button
        :if={is_nil(@working)}
        type="button"
        phx-click="dismiss_pi_reply"
        class="press -mr-1 inline-flex size-8 shrink-0 items-center justify-center rounded-full text-[color:var(--muted)] hover:bg-[var(--border)] hover:text-[var(--text)]"
        aria-label={gettext("Close")}
      >
        <.icon name="ph-x" class="size-4" />
      </button>
    </div>
    """
  end
end
