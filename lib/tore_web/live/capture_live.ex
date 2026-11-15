defmodule ToreWeb.CaptureLive do
  use ToreWeb, :live_view

  alias Tore.Capture.Router

  alias Tore.Home

  @impl true
  def mount(params, _session, socket) do
    return_to = ToreWeb.SafeReturn.path(params["return_to"], ~p"/")

    socket =
      socket
      |> assign(
        messages: [],
        input: "",
        loading: false,
        return_to: return_to
      )
      |> allow_upload(:chat_photos, accept: ~w(.jpg .jpeg .png), max_entries: 5)

    # The suggestions are the stored pick's, until a turn here suggests its own.
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Tore.PubSub, Home.swaps_topic(socket.assigns.current_user.id))

    {:ok, assign(socket, swaps: Home.current(socket.assigns.current_scope).swaps)}
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
    case Tore.Harness.Runs.revert(socket.assigns.current_scope, sid) do
      {:ok, _run} ->
        messages =
          Enum.map(socket.assigns.messages, fn
            %{run_stream_id: ^sid} = m -> Map.put(m, :reverted, true)
            other -> other
          end)

        {:noreply, assign(socket, messages: messages)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => text}, socket) do
    text = String.trim(text)

    images =
      consume_uploaded_entries(socket, :chat_photos, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    if text == "" and images == [] do
      {:noreply, socket}
    else
      history = socket.assigns.messages
      user_bubble = user_bubble_for(text, images)
      messages = history ++ [user_bubble]

      ctx = %{scope: socket.assigns.current_scope}

      ToreWeb.Background.run(
        fn -> Router.route(text, images, ctx, history) end,
        &{:route_complete, &1}
      )

      {:noreply, assign(socket, messages: messages, input: "", loading: true)}
    end
  end

  defp user_bubble_for("", images), do: %{role: :user, text: photo_label(length(images))}
  defp user_bubble_for(text, []), do: %{role: :user, text: text}

  defp user_bubble_for(text, images),
    do: %{role: :user, text: "#{text} (#{photo_label(length(images))})"}

  defp photo_label(1), do: gettext("1 photo")
  defp photo_label(n), do: gettext("%{n} photos", n: n)

  # Undo on a reply whose run can be undone, and "Reverted" once it has been.
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

  # A reply meant only for the model, such as a rejected memory batch, has no text.
  defp shown(bubbles), do: Enum.reject(bubbles, &(&1.role == :assistant and &1[:text] == ""))

  @impl true
  def handle_info({:quick_swaps, swaps}, socket), do: {:noreply, assign(socket, swaps: swaps)}

  def handle_info({:route_complete, {:ok, bubbles}}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> update(:messages, &(&1 ++ shown(bubbles)))}
  end

  def handle_info({:route_complete, {:error, _reason}}, socket) do
    bubble = %{
      role: :assistant,
      text: gettext("Tore couldn't finish that. Try again in a moment.")
    }

    {:noreply,
     socket
     |> assign(:loading, false)
     |> update(:messages, &(&1 ++ [bubble]))}
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
          <.icon name="hero-x-mark" class="size-5" />
        </.link>
      </div>

      <div id="chat-messages" class="scroll-quiet flex-1 overflow-y-auto px-4 py-4 space-y-3">
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
          class={[
            "flex",
            msg.role == :user && "justify-end",
            msg.role == :assistant && "justify-start"
          ]}
        >
          <div
            :if={Map.get(msg, :pantry_suggestions)}
            class="rise-in bg-[var(--sunken)] rounded-[20px] rounded-bl-md px-4 py-3 max-w-[85%] space-y-2"
          >
            <p class="text-sm text-[color:var(--text)]">{msg.text}</p>
            <ul class="space-y-1.5">
              <li :for={s <- msg.suggestions}>
                <.link
                  navigate={~p"/recipes"}
                  class="block text-[15px] font-semibold text-[color:var(--text)] underline underline-offset-4 decoration-[color:var(--subtle)]"
                >
                  {s.title}
                </.link>
                <p
                  :if={s.reasons != []}
                  class="text-xs text-[color:var(--muted)]"
                >
                  {Enum.join(s.reasons, " · ")}
                </p>
              </li>
            </ul>
          </div>
          <div
            :if={Map.get(msg, :shop_link)}
            class="rise-in bg-[var(--sunken)] rounded-[20px] rounded-bl-md px-4 py-3 max-w-[85%] space-y-2"
          >
            <p class="text-sm text-[color:var(--text)]">{msg.text}</p>
            <ul :if={Map.get(msg, :shopping_items, []) != []} class="space-y-0.5">
              <li
                :for={it <- Map.get(msg, :shopping_items, [])}
                class={[
                  "text-xs",
                  it.checked && "line-through text-[color:var(--muted)]",
                  !it.checked && "text-[color:var(--text)]"
                ]}
              >
                {it.name}<span :if={it.quantity}> · {it.quantity} {it.unit}</span>
              </li>
            </ul>
            <.link
              navigate={~p"/shop"}
              class="text-[15px] font-semibold text-[color:var(--text)] underline underline-offset-4 decoration-[color:var(--subtle)] whitespace-nowrap"
            >
              {gettext("Open shopping list")}
            </.link>
            <.undo msg={msg} />
          </div>
          <div
            :if={!Map.get(msg, :pantry_suggestions) && !Map.get(msg, :shop_link)}
            class={[
              "rise-in max-w-[85%] rounded-[20px] px-4 py-2.5 text-[15px] leading-relaxed flex flex-col gap-1",
              msg.role == :user && "rounded-br-md bg-[var(--text)] text-[color:var(--bg)]",
              msg.role == :assistant && "rounded-bl-md bg-[var(--sunken)]",
              msg.role == :assistant && !Map.get(msg, :quiet) && "text-[color:var(--text)]",
              Map.get(msg, :quiet) && "text-[color:var(--muted)] whitespace-pre-line"
            ]}
          >
            <span>{msg.text}</span>
            <.link
              :if={Map.get(msg, :kitchen_link)}
              navigate={~p"/settings#diet"}
              class="self-start text-[15px] font-semibold underline underline-offset-4 decoration-[color:var(--subtle)] whitespace-nowrap"
            >
              {gettext("Open diet and allergies")}
            </.link>
            <.undo msg={msg} />
          </div>
        </div>
        <div :if={@loading} class="flex justify-start">
          <div
            role="status"
            class="rise-in flex items-center gap-2 rounded-[20px] rounded-bl-md bg-[var(--sunken)] px-4 py-2.5"
          >
            <.icon
              name="hero-arrow-path"
              class="size-4 text-[color:var(--muted)] motion-safe:animate-spin"
            />
            <span class="text-[15px] text-[color:var(--muted)]">{gettext("Working on it…")}</span>
          </div>
        </div>
      </div>

      <div class="px-4 pt-2 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]">
        <div
          :if={@swaps != [] and not @loading}
          data-role="swaps"
          class="scroll-quiet -mx-4 mb-2 flex gap-2 overflow-x-auto px-4"
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
              <.icon name="hero-camera" class="size-5" />
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
              <.icon name="hero-arrow-up" class="size-5" />
            </button>
          </div>
          <div :if={@uploads.chat_photos.entries != []} class="flex flex-wrap items-center gap-2">
            <span
              :for={entry <- @uploads.chat_photos.entries}
              class="num inline-flex h-8 items-center gap-1.5 rounded-full bg-[var(--sunken)] px-3 text-[13px] text-[color:var(--text)]"
            >
              <.icon name="hero-photo" class="size-4 text-[color:var(--muted)]" />
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
