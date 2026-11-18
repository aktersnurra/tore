defmodule ToreWeb.CaptureLive do
  @moduledoc """
  The chat with Tore: the person's own pi session (`Tore.Pi.chat_session/1`). What they send
  goes to pi, photos with it; pi's answer streams in, and each change it makes in Tore shows as a
  receipt with Undo, read from the tool's result. The conversation is pi's, so opening the tray
  shows it from where it was.
  """
  use ToreWeb, :live_view

  alias Tore.{Home, Pi}
  alias Tore.Harness.Runs

  # How much of the conversation the tray shows when it opens.
  @history_bubbles 60

  @impl true
  def mount(params, _session, socket) do
    return_to = ToreWeb.SafeReturn.path(params["return_to"], ~p"/")
    scope = socket.assigns.current_scope
    session = Pi.chat_session(scope)

    socket =
      socket
      |> assign(
        session: session,
        messages: [],
        draft: nil,
        input: params["q"] || "",
        loading: false,
        working: nil,
        return_to: return_to
      )
      |> allow_upload(:chat_photos, accept: ~w(.jpg .jpeg .png), max_entries: 5)

    socket =
      if connected?(socket) do
        # The suggestions are the stored pick's, until a turn here suggests its own.
        Phoenix.PubSub.subscribe(Tore.PubSub, Home.swaps_topic(socket.assigns.current_user.id))
        Pi.subscribe(scope, session)
        start_async(socket, :history, fn -> history(scope, session) end)
      else
        socket
      end

    {:ok, assign(socket, swaps: Home.current(scope).swaps)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("close_tray", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  def handle_event("swap", %{"index" => index}, socket) do
    case Enum.at(socket.assigns.swaps, String.to_integer(index)) do
      %{action: {:open, screen}} -> {:noreply, push_navigate(socket, to: Home.path(screen))}
      %{action: {:prompt, text}} -> handle_event("send_message", %{"message" => text}, socket)
      nil -> {:noreply, socket}
    end
  end

  def handle_event("undo_run", %{"sid" => sid}, socket) do
    case Runs.revert(socket.assigns.current_scope, sid) do
      {:ok, _run} -> {:noreply, update(socket, :messages, &reverted(&1, sid))}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("send_message", %{"message" => text}, socket) do
    text = String.trim(text)

    images =
      consume_uploaded_entries(socket, :chat_photos, fn %{path: path}, entry ->
        {:ok, {entry.client_type, File.read!(path)}}
      end)

    if text == "" and images == [] do
      {:noreply, socket}
    else
      %{current_scope: scope, session: session} = socket.assigns
      bubble = user_bubble_for(text, length(images))

      socket = socket |> assign(input: "") |> update(:messages, &(&1 ++ [bubble]))

      case Pi.ask(scope, session, if(text == "", do: bubble.text, else: text), images: images) do
        :ok ->
          {:noreply, assign(socket, loading: true, working: first_step(text, images))}

        {:error, reason} ->
          {:noreply, update(socket, :messages, &(&1 ++ [refusal(reason)]))}
      end
    end
  end

  @impl true
  def handle_async(:history, {:ok, {:ok, bubbles}}, socket),
    do: {:noreply, update(socket, :messages, &(bubbles ++ &1))}

  # No pi, or pi couldn't be reached: the tray opens empty, and sending says why.
  def handle_async(:history, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:quick_swaps, swaps}, socket), do: {:noreply, assign(socket, swaps: swaps)}

  # pi's events, heard while it answers something sent from here.
  def handle_info({:pi, _session, _event}, %{assigns: %{loading: false}} = socket),
    do: {:noreply, socket}

  def handle_info({:pi, _session, event}, socket), do: {:noreply, pi_event(event, socket)}

  defp pi_event(
         %{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta"} = e},
         socket
       ),
       do: assign(socket, draft: (socket.assigns.draft || "") <> e["delta"])

  defp pi_event(%{"type" => "message_end", "message" => %{"role" => "assistant"} = m}, socket) do
    case Pi.assistant_text(m) do
      nil -> assign(socket, draft: nil)
      text -> socket |> assign(draft: nil) |> append(%{role: :assistant, text: text})
    end
  end

  defp pi_event(%{"type" => "tool_execution_start", "toolName" => name}, socket),
    do: assign(socket, working: step_label(tool(name)) || socket.assigns.working)

  defp pi_event(%{"type" => "tool_execution_end", "isError" => false} = event, socket) do
    case {tool(event["toolName"]), receipt(event["result"])} do
      # Undone by asking: the change's own receipt says so.
      {"undo", %{run_stream_id: id}} -> update(socket, :messages, &reverted(&1, id))
      {_tool, nil} -> socket
      {_tool, receipt} -> append(socket, receipt)
    end
  end

  defp pi_event(%{"type" => "agent_settled"}, socket),
    do: assign(socket, loading: false, working: nil, draft: nil)

  defp pi_event(%{"type" => "exited"}, socket) do
    socket
    |> assign(loading: false, working: nil, draft: nil)
    |> append(refusal(:exited))
  end

  defp pi_event(_event, socket), do: socket

  defp append(socket, bubble), do: update(socket, :messages, &(&1 ++ [bubble]))

  defp reverted(messages, id) do
    Enum.map(messages, fn
      %{run_stream_id: ^id} = m -> Map.put(m, :reverted, true)
      other -> other
    end)
  end

  # ----- the conversation as pi keeps it ----------------------------------------------------

  defp history(scope, session) do
    with {:ok, messages} <- Pi.messages(scope, session) do
      bubbles = messages |> Enum.flat_map(&bubbles/1) |> Enum.take(-@history_bubbles)
      ids = for %{run_stream_id: id} <- bubbles, do: id
      statuses = Runs.statuses(scope, ids)

      {:ok,
       Enum.map(bubbles, fn
         %{run_stream_id: id} = b -> Map.put(b, :reverted, statuses[id] == :reverted)
         b -> b
       end)}
    end
  end

  defp bubbles(%{"role" => "user", "content" => content}) do
    {texts, photos} = user_content(content)
    [user_bubble_for(Enum.join(texts, "\n"), photos)]
  end

  defp bubbles(%{"role" => "assistant"} = message) do
    case Pi.assistant_text(message) do
      nil -> []
      text -> [%{role: :assistant, text: text}]
    end
  end

  defp bubbles(%{"role" => "toolResult", "isError" => false} = message) do
    case {tool(message["toolName"]), receipt(message)} do
      {"undo", _} -> []
      {_tool, nil} -> []
      {_tool, receipt} -> [receipt]
    end
  end

  defp bubbles(_message), do: []

  defp user_content(text) when is_binary(text), do: {[text], 0}

  defp user_content(blocks) when is_list(blocks) do
    {for(%{"type" => "text", "text" => t} <- blocks, do: t),
     Enum.count(blocks, &(&1["type"] == "image"))}
  end

  # A change Tore made for pi answers `{"done": …, "run_id": …}`: its receipt, with Undo.
  defp receipt(%{"content" => [%{"type" => "text", "text" => text} | _]}) do
    case Jason.decode(text) do
      {:ok, %{"done" => done, "run_id" => id}} when is_binary(done) and is_binary(id) ->
        %{role: :assistant, text: done, run_stream_id: id, quiet: true}

      _ ->
        nil
    end
  end

  defp receipt(_result), do: nil

  # pi names Tore's tools `mcp__tore__<tool>`.
  defp tool(name) when is_binary(name), do: String.replace_prefix(name, "mcp__tore__", "")
  defp tool(_name), do: nil

  # ----- bubbles ----------------------------------------------------------------------------

  defp user_bubble_for(text, 0), do: %{role: :user, text: text}
  defp user_bubble_for("", photos), do: %{role: :user, text: photo_label(photos)}

  defp user_bubble_for(text, photos),
    do: %{role: :user, text: "#{text} (#{photo_label(photos)})"}

  defp photo_label(1), do: gettext("1 photo")
  defp photo_label(n), do: gettext("%{n} photos", n: n)

  defp refusal(reason) do
    text =
      Tore.LLM.refusal_text(reason) ||
        gettext("Tore couldn't finish that. Try again in a moment.")

    %{role: :assistant, text: text}
  end

  # What Tore is doing, named as the kitchen would: before any tool runs, and as each starts.
  defp first_step(_text, [_ | _]), do: gettext("Reading the photo…")

  defp first_step(text, []) do
    if text =~ ~r{https?://},
      do: gettext("Reading the link…"),
      else: gettext("Checking the kitchen…")
  end

  defp step_label("log_receipt"), do: gettext("Reading the receipt…")
  defp step_label("save_recipe"), do: gettext("Reading the recipe…")
  defp step_label(n) when n in ~w(web_search fetch_content), do: gettext("Reading the link…")

  defp step_label(n) when n in ~w(search_recipes get_recipe),
    do: gettext("Looking through the recipes…")

  defp step_label(n) when n in ~w(add_to_pantry remove_from_pantry),
    do: gettext("Checking what's at home…")

  defp step_label(n) when n in ~w(set_dinner change_day mark_cooked),
    do: gettext("Changing the plan…")

  defp step_label("make_list"), do: gettext("Making the list…")

  defp step_label(n) when n in ~w(add_to_list check_off remove_from_list),
    do: gettext("Going through the list…")

  defp step_label(_name), do: nil

  # Undo on a receipt whose change can be undone, and "Reverted" once it has been.
  attr :msg, :map, required: true

  defp undo(assigns) do
    ~H"""
    <button
      :if={Map.get(@msg, :run_stream_id) && !Map.get(@msg, :reverted)}
      type="button"
      phx-click="undo_run"
      phx-value-sid={@msg.run_stream_id}
      class="self-start block text-[13px] font-semibold underline underline-offset-4 decoration-[color:var(--subtle)] mt-1"
    >
      {gettext("Undo")}
    </button>
    <span :if={Map.get(@msg, :reverted)} class="block text-xs text-[color:var(--muted)] mt-1">
      {gettext("Reverted")}
    </span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="command-tray"
      data-role="command-tray"
      phx-mounted={
        JS.transition(
          {"motion-safe:transition-transform motion-safe:duration-200 ease-out", "translate-y-full",
           "translate-y-0"}
        )
      }
      class="fixed inset-x-0 bottom-0 top-8 z-50 mx-auto flex max-w-2xl flex-col rounded-t-[28px] bg-[var(--surface)] shadow-[var(--shadow-pop)]"
      phx-window-keydown="close_tray"
      phx-key="Escape"
    >
      <div class="flex justify-center py-2">
        <.link navigate={@return_to} aria-label={gettext("Close")} data-role="tray-close">
          <span class="w-10 h-1.5 rounded-full bg-[color:var(--border)] block"></span>
        </.link>
      </div>

      <div class="flex items-center justify-between gap-3 px-4 pb-1">
        <span class="t-eyebrow pl-1">{gettext("Ask Tore")}</span>
        <.link
          navigate={@return_to}
          aria-label={gettext("Close")}
          class="press flex size-10 items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)] hover:bg-[var(--border)]"
        >
          <.icon name="ph-x" class="size-5" />
        </.link>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        // The latest of the conversation is in view: when it opens, and as the answer comes in,
        // unless they have scrolled up to read.
        export default {
          mounted() { this.el.scrollTop = this.el.scrollHeight },
          beforeUpdate() {
            this.atEnd = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
          },
          updated() { if (this.atEnd) this.el.scrollTop = this.el.scrollHeight },
        }
      </script>
      <div
        id="chat-messages"
        phx-hook=".ScrollBottom"
        class="flex-1 overflow-y-auto px-4 py-4 space-y-3"
      >
        <div
          :if={@messages == [] and not @loading}
          class="flex h-full flex-col items-start justify-end pb-4"
        >
          <p class="reveal t-display" style="--i: 0">{gettext("What do you need?")}</p>
          <p
            class="reveal mt-3 max-w-[32ch] text-[color:var(--muted)]"
            style="--i: 1; font-size: 15px; line-height: 1.5;"
          >
            {gettext(
              "Ask about dinner, add to the list, or send a photo of a receipt, a recipe or the fridge."
            )}
          </p>
        </div>
        <div
          :for={msg <- @messages}
          data-role={"bubble-#{msg.role}"}
          class={[
            "flex",
            msg.role == :user && "justify-end",
            msg.role == :assistant && "justify-start"
          ]}
        >
          <div class={[
            "rise-in max-w-[85%] rounded-[20px] px-4 py-2.5 text-[15px] leading-relaxed flex flex-col gap-1 whitespace-pre-line",
            msg.role == :user && "rounded-br-md bg-[var(--text)] text-[color:var(--bg)]",
            msg.role == :assistant && "rounded-bl-md bg-[var(--sunken)]",
            msg.role == :assistant && !Map.get(msg, :quiet) && "text-[color:var(--text)]",
            Map.get(msg, :quiet) && "text-[color:var(--muted)]"
          ]}>
            <span>{msg.text}</span>
            <.undo msg={msg} />
          </div>
        </div>
        <div :if={@draft} data-role="draft" class="flex justify-start">
          <div class="max-w-[85%] rounded-[20px] rounded-bl-md bg-[var(--sunken)] px-4 py-2.5 text-[15px] leading-relaxed whitespace-pre-line text-[color:var(--text)]">
            {@draft}
          </div>
        </div>
        <div :if={@loading and is_nil(@draft)} class="flex justify-start">
          <div
            role="status"
            class="rise-in flex items-center gap-2 rounded-[20px] rounded-bl-md bg-[var(--sunken)] px-4 py-2.5"
          >
            <.icon
              name="ph-arrows-clockwise"
              class="size-4 text-[color:var(--muted)] motion-safe:animate-spin"
            />
            <span
              id={"working-#{:erlang.phash2(@working)}"}
              data-role="working"
              class="settle text-[15px] text-[color:var(--muted)]"
            >
              {@working}
            </span>
          </div>
        </div>
      </div>

      <div class="px-4 pt-2 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]">
        <div
          :if={@swaps != [] and not @loading}
          data-role="swaps"
          class="-mx-4 mb-2 flex gap-2 overflow-x-auto px-4"
        >
          <button
            :for={{swap, index} <- Enum.with_index(@swaps)}
            type="button"
            phx-click="swap"
            phx-value-index={index}
            data-role="swap"
            class="pill press"
          >
            {swap.label}
          </button>
        </div>
        <form phx-submit="send_message" phx-change="validate" class="flex flex-col gap-2">
          <div class="flex items-center gap-2">
            <label
              for={@uploads.chat_photos.ref}
              aria-label={gettext("Attach photo")}
              title={gettext("Attach photo")}
              class="press flex size-12 shrink-0 cursor-pointer items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)] hover:bg-[var(--border)]"
            >
              <.icon name="ph-camera" class="size-5" />
            </label>
            <input
              type="text"
              name="message"
              value={@input}
              placeholder={gettext("Ask anything about meals, groceries…")}
              autocomplete="off"
              class="h-12 min-w-0 flex-1 rounded-full bg-[var(--sunken)] px-5 text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus-visible:outline-2 focus-visible:outline-[color:var(--accent)]"
              style="font-size: 16px;"
            />
            <button
              type="submit"
              disabled={@loading}
              aria-label={gettext("Send")}
              class="press flex size-12 shrink-0 items-center justify-center rounded-full bg-[color:var(--accent)] text-[color:var(--on-accent)] hover:bg-[color:var(--accent-hover)] disabled:opacity-40"
            >
              <.icon name="ph-arrow-up" class="size-5" />
            </button>
          </div>
          <div :if={@uploads.chat_photos.entries != []} class="flex flex-wrap items-center gap-2">
            <span
              :for={entry <- @uploads.chat_photos.entries}
              class="num inline-flex h-8 items-center gap-1.5 rounded-full bg-[var(--sunken)] px-3 text-[13px] text-[color:var(--text)]"
            >
              <.icon name="ph-image" class="size-4 text-[color:var(--muted)]" />
              {entry.client_name} · {entry.progress}%
            </span>
          </div>
          <.live_file_input upload={@uploads.chat_photos} class="hidden" />
        </form>
      </div>
    </div>
    """
  end
end
