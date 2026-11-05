defmodule ToreWeb.CaptureLive do
  use ToreWeb, :live_view

  alias Tore.Capture.Router
  alias Tore.Harness.RunReceipts

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

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("close_tray", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  def handle_event("undo_run", %{"sid" => sid}, socket) do
    case RunReceipts.revert(sid) do
      :ok ->
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

      ctx = %{
        household_id: Tore.Household.get_household!().id,
        user_id: socket.assigns.current_user && socket.assigns.current_user.id,
        locale: socket.assigns.current_user && socket.assigns.current_user.locale
      }

      pid = self()

      Task.start(fn ->
        result = Router.route(text, images, ctx, history)
        send(pid, {:route_complete, result})
      end)

      {:noreply, assign(socket, messages: messages, input: "", loading: true)}
    end
  end

  defp user_bubble_for("", images), do: %{role: :user, text: photo_label(length(images))}
  defp user_bubble_for(text, []), do: %{role: :user, text: text}

  defp user_bubble_for(text, images),
    do: %{role: :user, text: "#{text} (#{photo_label(length(images))})"}

  defp photo_label(1), do: gettext("1 photo")
  defp photo_label(n), do: gettext("%{n} photos", n: n)

  @impl true
  def handle_info({:route_complete, {:ok, bubbles}}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> update(:messages, &(&1 ++ bubbles))}
  end

  def handle_info({:route_complete, {:error, _reason}}, socket) do
    bubble = %{
      role: :assistant,
      text: gettext("Sorry, I couldn't process that. Please try again.")
    }

    {:noreply,
     socket
     |> assign(:loading, false)
     |> update(:messages, &(&1 ++ [bubble]))}
  end

  def handle_info({:run_event, _stream_id, _event}, socket), do: {:noreply, socket}
  def handle_info({:run_state_changed, _stream_id, _state}, socket), do: {:noreply, socket}

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
      class="fixed inset-x-0 bottom-0 top-8 z-50 rounded-t-2xl bg-[var(--surface)] border-t border-[color:var(--border)] flex flex-col"
      phx-window-keydown="close_tray"
      phx-key="Escape"
    >
      <div class="flex justify-center py-2">
        <.link navigate={@return_to} aria-label={gettext("Close")} data-role="tray-close">
          <span class="w-10 h-1.5 rounded-full bg-[color:var(--border)] block"></span>
        </.link>
      </div>

      <div class="flex items-center gap-3 px-4 py-3 border-b border-[color:var(--border)]">
        <.link
          navigate={@return_to}
          class="text-[color:var(--muted)] hover:text-[color:var(--text)]"
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <span class="font-semibold text-[color:var(--text)]">{gettext("Ask Tore")}</span>
      </div>

      <div id="chat-messages" class="flex-1 overflow-y-auto px-4 py-4 space-y-4">
        <div
          :for={msg <- @messages}
          class={[
            "flex",
            msg.role == :user && "justify-end",
            msg.role == :assistant && "justify-start"
          ]}
        >
          <div
            :if={Map.get(msg, :review_link)}
            class="bg-[var(--surface)] border border-[color:var(--border)] rounded-2xl px-4 py-3 max-w-[80%]"
          >
            <p class="text-sm text-[color:var(--text)] mb-2">{msg.text}</p>
            <.link
              href={~p"/review"}
              class="text-sm text-[color:var(--accent)] font-semibold whitespace-nowrap"
            >
              {gettext("Review")} →
            </.link>
          </div>
          <div
            :if={Map.get(msg, :recipe_card)}
            class="bg-[var(--surface)] border border-[color:var(--border)] rounded-2xl px-4 py-3 max-w-[80%]"
          >
            <p class="text-sm text-[color:var(--text)] mb-2">
              {gettext("Imported")} <span class="font-semibold">{msg.title}</span>.
            </p>
            <.link
              navigate={~p"/recipes"}
              class="text-sm text-[color:var(--accent)] font-semibold whitespace-nowrap"
            >
              {gettext("Open recipe")} →
            </.link>
          </div>
          <div
            :if={Map.get(msg, :pantry_suggestions)}
            class="bg-[var(--surface)] border border-[color:var(--border)] rounded-2xl px-4 py-3 max-w-[80%] space-y-2"
          >
            <p class="text-sm text-[color:var(--text)]">{msg.text}</p>
            <ul class="space-y-1.5">
              <li :for={s <- msg.suggestions}>
                <.link
                  navigate={~p"/recipes"}
                  class="block text-sm text-[color:var(--accent)] font-semibold"
                >
                  {s.title} →
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
            class="bg-[var(--surface)] border border-[color:var(--border)] rounded-2xl px-4 py-3 max-w-[80%] space-y-2"
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
              class="text-sm text-[color:var(--accent)] font-semibold whitespace-nowrap"
            >
              {gettext("Open shopping list")} →
            </.link>
          </div>
          <div
            :if={
              !Map.get(msg, :review_link) && !Map.get(msg, :recipe_card) &&
                !Map.get(msg, :pantry_suggestions) && !Map.get(msg, :shop_link)
            }
            class={[
              "max-w-[80%] rounded-2xl px-4 py-2.5 text-sm leading-relaxed flex flex-col gap-1",
              msg.role == :user && "bg-[color:var(--accent)] text-white",
              msg.role == :assistant &&
                "bg-[var(--surface)] border border-[color:var(--border)] text-[color:var(--text)]"
            ]}
          >
            <span>{msg.text}</span>
            <button
              :if={Map.get(msg, :run_stream_id) && !Map.get(msg, :reverted)}
              type="button"
              phx-click="undo_run"
              phx-value-sid={msg.run_stream_id}
              class="self-start text-xs text-[color:var(--accent)] font-semibold mt-1"
            >
              {gettext("Undo")}
            </button>
            <span
              :if={Map.get(msg, :reverted)}
              class="text-xs text-[color:var(--muted)] mt-1"
            >
              {gettext("Reverted")}
            </span>
          </div>
        </div>
        <div :if={@loading} class="flex justify-start">
          <div class="bg-[var(--surface)] border border-[color:var(--border)] rounded-2xl px-4 py-2.5">
            <span class="text-[color:var(--muted)] text-sm">{gettext("Thinking…")}</span>
          </div>
        </div>
      </div>

      <div class="px-4 py-3 border-t border-[color:var(--border)]">
        <form phx-submit="send_message" phx-change="validate" class="flex flex-col gap-2">
          <div class="flex items-center gap-2">
            <input
              type="text"
              name="message"
              value={@input}
              placeholder={gettext("Ask anything about meals, groceries…")}
              autocomplete="off"
              class="flex-1 rounded-full border border-[color:var(--border)] bg-[var(--surface)] px-4 py-2.5 text-sm text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none"
            />
            <button
              type="submit"
              disabled={@loading}
              class="flex-shrink-0 w-10 h-10 rounded-full bg-[color:var(--accent)] flex items-center justify-center disabled:opacity-40"
            >
              <.icon name="hero-paper-airplane" class="size-4 text-white" />
            </button>
          </div>
          <div class="flex items-center gap-2 flex-wrap">
            <label
              for={@uploads.chat_photos.ref}
              class="text-xs text-[color:var(--muted)] flex items-center gap-1 cursor-pointer w-fit"
            >
              <.icon name="hero-camera" class="size-3.5" /> {gettext("Attach photo")}
            </label>
            <span
              :for={entry <- @uploads.chat_photos.entries}
              class="text-xs text-[color:var(--accent)]"
            >
              {entry.client_name} ({entry.progress}%)
            </span>
          </div>
          <.live_file_input upload={@uploads.chat_photos} class="hidden" />
        </form>
      </div>
    </div>
    """
  end
end
