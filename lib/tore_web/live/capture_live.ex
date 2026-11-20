defmodule ToreWeb.CaptureLive do
  @moduledoc """
  The chat with Tore: the person's own pi session (`Tore.Pi.chat_session/1`). What they send
  goes to pi, photos with it; pi's answer streams in, and each change it makes in Tore shows as a
  receipt with Undo, read from the tool's result. The conversation is pi's, so opening the tray
  shows it from where it was.

  Opened from a recipe (`?recipe=<id>`), the tray is the person's conversation about that recipe
  (`Tore.Pi.recipe_chat_session/2`), so coming back to the recipe comes back to it. Its first
  message says which recipe it's about, and the kitchen's quick swaps stay with the main chat.
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
    recipe = recipe(scope, params["recipe"])

    session =
      if recipe, do: Pi.recipe_chat_session(scope, recipe.id), else: Pi.chat_session(scope)

    socket =
      socket
      |> assign(
        session: session,
        recipe: recipe,
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
        Pi.subscribe(scope, session)
        start_async(socket, :history, fn -> history(scope, session) end)
      else
        socket
      end

    {:ok, assign(socket, swaps: if(recipe, do: [], else: Home.current(scope).swaps))}
  end

  defp recipe(scope, id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> Tore.Recipes.get(scope, id)
      _ -> nil
    end
  end

  defp recipe(_scope, _id), do: nil

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

  # Stops what pi is doing. What it had written so far stays, and the rest of that run is let go:
  # its events arrive while the tray isn't waiting, so they're ignored.
  def handle_event("stop", _params, socket) do
    %{current_scope: scope, session: session, draft: draft} = socket.assigns
    :ok = Pi.abort(scope, session)

    socket =
      if draft, do: append(socket, %{role: :assistant, text: draft}), else: socket

    {:noreply, assign(socket, loading: false, working: nil, draft: nil)}
  end

  def handle_event("send_message", %{"message" => text}, socket) do
    text = String.trim(text)

    images =
      consume_uploaded_entries(socket, :chat_photos, fn %{path: path}, entry ->
        {:ok, {MIME.from_path(entry.client_name), File.read!(path)}}
      end)

    if text == "" and images == [] do
      {:noreply, socket}
    else
      %{current_scope: scope, session: session, recipe: recipe, messages: before} = socket.assigns
      bubble = user_bubble_for(text, length(images))
      message = about(recipe, before, if(text == "", do: bubble.text, else: text))

      socket = socket |> assign(input: "") |> update(:messages, &(&1 ++ [bubble]))

      case Pi.ask(scope, session, message, images: images) do
        :ok ->
          {:noreply, assign(socket, loading: true, working: first_step(text, images))}

        {:error, reason} ->
          {:noreply, update(socket, :messages, &(&1 ++ [refusal(reason)]))}
      end
    end
  end

  # A recipe's conversation says what it's about as it starts.
  defp about(nil, _before, message), do: message

  defp about(recipe, [], message),
    do: "From the recipe page, about #{recipe.title} (recipe #{recipe.id}): #{message}"

  defp about(_recipe, _before, message), do: message

  @impl true
  def handle_async(:history, {:ok, {:ok, bubbles}}, socket),
    do: {:noreply, update(socket, :messages, &(bubbles ++ &1))}

  # No pi, or pi couldn't be reached: the tray opens empty, and sending says why.
  def handle_async(:history, _result, socket), do: {:noreply, socket}

  # pi's events, heard while it answers something sent from here.
  @impl true
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
      Tore.Pi.refusal_text(reason) ||
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

  # ----- the page ---------------------------------------------------------------------------

  # pi writes markdown: lists, bold, links. Raw HTML in it is dropped (MDEx's default).
  defp markdown(text),
    do: raw(MDEx.to_html!(text, extension: [autolink: true, strikethrough: true]))

  defp avatar(assigns) do
    ~H"""
    <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-[color:var(--accent)] text-[color:var(--on-accent)]">
      <.icon name="ph-cooking-pot-duotone" class="size-4" />
    </span>
    """
  end

  # Whether each message starts a run of Tore's: only the first gets Tore's mark and name.
  defp with_heads(messages) do
    {turns, _previous} =
      Enum.map_reduce(messages, nil, fn msg, previous ->
        {{msg, not tore?(previous)}, msg}
      end)

    turns
  end

  defp tore?(%{role: :assistant}), do: true
  defp tore?(_msg), do: false

  # One message. Theirs sits on the right in a soft bubble; Tore's is reading text, under its name
  # when it starts a run. A change pi made is a quiet line with its Undo.
  attr :msg, :map, required: true
  attr :head, :boolean, default: true

  defp turn(%{msg: %{quiet: true}} = assigns) do
    ~H"""
    <div data-role="bubble-assistant" class="rise-in flex items-start gap-2 pl-10 text-[15px]">
      <.icon
        name={if Map.get(@msg, :reverted), do: "ph-arrow-u-up-left", else: "ph-check-circle-fill"}
        class="mt-0.5 size-[18px] shrink-0 text-[color:var(--muted)]"
      />
      <div class="min-w-0 flex-1 text-[color:var(--muted)]">
        <span>{@msg.text}</span>
        <.undo msg={@msg} />
      </div>
    </div>
    """
  end

  defp turn(%{msg: %{role: :user}} = assigns) do
    ~H"""
    <div data-role="bubble-user" class="rise-in flex justify-end pl-10">
      <div class="max-w-[85%] rounded-[18px] bg-[var(--sunken)] px-4 py-2.5 text-[16px] leading-relaxed text-[color:var(--text)]">
        <span class="whitespace-pre-line">{@msg.text}</span>
      </div>
    </div>
    """
  end

  defp turn(assigns) do
    ~H"""
    <div data-role="bubble-assistant" class={["rise-in flex items-start gap-3", !@head && "pl-10"]}>
      <.avatar :if={@head} />
      <div class="min-w-0 flex-1 pt-0.5">
        <div :if={@head} class="mb-1 text-[14px] font-semibold text-[color:var(--text)]">Tore</div>
        <div class="chat-md text-[color:var(--text)]">{markdown(@msg.text)}</div>
      </div>
    </div>
    """
  end

  # Undo on a receipt whose change can be undone, and "Reverted" once it has been.
  attr :msg, :map, required: true

  defp undo(assigns) do
    ~H"""
    <button
      :if={Map.get(@msg, :run_stream_id) && !Map.get(@msg, :reverted)}
      type="button"
      phx-click="undo_run"
      phx-value-sid={@msg.run_stream_id}
      class="press ml-1 text-[14px] font-semibold text-[color:var(--text)] underline underline-offset-4 decoration-[color:var(--subtle)] hover:decoration-[color:var(--text)]"
    >
      {gettext("Undo")}
    </button>
    <span :if={Map.get(@msg, :reverted)} class="ml-1 text-[13px]">
      · {gettext("Reverted")}
    </span>
    """
  end

  @impl true
  def render(assigns) do
    # What pi is writing now starts a run of Tore's only after someone else's message.
    assigns = assign(assigns, :head, not tore?(List.last(assigns.messages)))

    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <%!-- On a wide screen the chat is a page beside the menu; on a phone it's a sheet over it. --%>
      <div
        id="command-tray"
        data-role="command-tray"
        phx-mounted={
          JS.transition(
            {"motion-safe:transition-transform motion-safe:duration-200 ease-out", "translate-y-full",
             "translate-y-0"}
          )
        }
        class="fixed inset-x-0 bottom-0 top-8 z-50 flex flex-col rounded-t-[28px] bg-[var(--bg)] shadow-[var(--shadow-pop)] lg:inset-y-0 lg:right-0 lg:left-[248px] lg:z-30 lg:rounded-none lg:shadow-none"
        phx-window-keydown="close_tray"
        phx-key="Escape"
      >
        <div class="flex justify-center py-2 lg:hidden">
          <.link navigate={@return_to} aria-label={gettext("Close")} data-role="tray-close">
            <span class="block h-1.5 w-10 rounded-full bg-[color:var(--border)]"></span>
          </.link>
        </div>

        <header class="flex h-12 shrink-0 items-center justify-between gap-3 border-b border-[color:var(--hairline)] px-4 lg:h-14">
          <span class="truncate text-[15px] font-semibold text-[color:var(--text)]">
            {if @recipe,
              do: gettext("About %{dish}", dish: @recipe.title),
              else: gettext("Ask Tore")}
          </span>
          <.link
            navigate={@return_to}
            aria-label={gettext("Close")}
            class="press flex size-9 items-center justify-center rounded-full text-[color:var(--muted)] hover:bg-[var(--sunken)] hover:text-[color:var(--text)] focus-visible:outline-2 focus-visible:outline-[color:var(--accent)]"
          >
            <.icon name="ph-x" class="size-5" />
          </.link>
        </header>

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
        <div id="chat-messages" phx-hook=".ScrollBottom" class="flex-1 overflow-y-auto">
          <div class="mx-auto flex min-h-full w-full max-w-3xl flex-col px-4 py-6">
            <div
              :if={@messages == [] and not @loading}
              class="my-auto flex flex-col items-center py-10 text-center"
            >
              <span
                class="reveal flex size-12 items-center justify-center rounded-full bg-[color:var(--accent)] text-[color:var(--on-accent)]"
                style="--i: 0"
              >
                <.icon name="ph-cooking-pot-duotone" class="size-6" />
              </span>
              <p
                class="reveal mt-4 text-[26px] font-semibold tracking-[-0.02em] text-[color:var(--text)]"
                style="--i: 1"
              >
                {gettext("What do you need?")}
              </p>
              <p
                class="reveal mt-2 max-w-[38ch] text-[color:var(--muted)]"
                style="--i: 2; font-size: 15px; line-height: 1.5;"
              >
                {if @recipe,
                  do:
                    gettext(
                      "Make it simpler, for six, or without something. This conversation is here when you come back to the recipe."
                    ),
                  else:
                    gettext(
                      "Ask about dinner, add to the list, or send a photo of a receipt, a recipe or the fridge."
                    )}
              </p>
            </div>

            <div class="space-y-6">
              <.turn :for={{msg, head} <- with_heads(@messages)} msg={msg} head={head} />

              <div
                :if={@draft}
                data-role="draft"
                class={["flex items-start gap-3", !@head && "pl-10"]}
              >
                <.avatar :if={@head} />
                <div class="min-w-0 flex-1 pt-0.5">
                  <div :if={@head} class="mb-1 text-[14px] font-semibold text-[color:var(--text)]">
                    Tore
                  </div>
                  <div class="chat-md is-streaming text-[color:var(--text)]">
                    {markdown(@draft)}
                  </div>
                </div>
              </div>

              <div
                :if={@loading and is_nil(@draft)}
                class={["rise-in flex items-start gap-3", !@head && "pl-10"]}
              >
                <.avatar :if={@head} />
                <div class="min-w-0 flex-1 pt-0.5">
                  <div :if={@head} class="mb-1 text-[14px] font-semibold text-[color:var(--text)]">
                    Tore
                  </div>
                  <div role="status" class="flex items-center gap-2">
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
            </div>
          </div>
        </div>

        <div class="mx-auto w-full max-w-3xl px-4 pt-2 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] lg:pb-6">
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

          <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
            // The box grows with what's written, up to a point. Enter sends and Shift+Enter starts a
            // new line; once sent, the box empties for the next message.
            export default {
              mounted() {
                this.grow = () => {
                  this.el.style.height = "auto"
                  this.el.style.height = Math.min(this.el.scrollHeight, 192) + "px"
                }
                this.el.addEventListener("input", this.grow)
                this.el.addEventListener("keydown", (e) => {
                  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                    e.preventDefault()
                    // While pi works, Enter waits: Stop is where send was.
                    if (!this.el.form.querySelector('[data-role="stop"]')) this.el.form.requestSubmit()
                  }
                })
                // After LiveView has read the form.
                this.el.form.addEventListener("submit", () =>
                  setTimeout(() => { this.el.value = ""; this.grow() }, 0))
                this.grow()
              },
              updated() { this.grow() },
            }
          </script>
          <form phx-submit="send_message" phx-change="validate">
            <div class="field-group flex items-end gap-2 rounded-[20px] border border-[color:var(--border)] bg-[var(--surface)] py-2 pr-2 pl-4">
              <textarea
                id="chat-input"
                name="message"
                rows="1"
                phx-hook=".Composer"
                placeholder={gettext("Message Tore…")}
                aria-label={gettext("Message Tore…")}
                autocomplete="off"
                class="block max-h-48 min-w-0 flex-1 resize-none self-center bg-transparent py-1.5 leading-relaxed text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none"
                style="font-size: 16px;"
              >{@input}</textarea>
              <button
                :if={not @loading}
                type="submit"
                aria-label={gettext("Send")}
                title={gettext("Send")}
                class="press flex size-9 shrink-0 items-center justify-center rounded-full text-[color:var(--muted)] hover:bg-[var(--sunken)] hover:text-[color:var(--text)]"
              >
                <.icon name="ph-arrow-elbow-down-left" class="size-5" />
              </button>
              <button
                :if={@loading}
                type="button"
                phx-click="stop"
                data-role="stop"
                aria-label={gettext("Stop")}
                title={gettext("Stop")}
                class="press flex size-9 shrink-0 items-center justify-center rounded-full bg-[color:var(--accent)] text-[color:var(--on-accent)] hover:bg-[color:var(--accent-hover)]"
              >
                <.icon name="ph-stop-fill" class="size-4" />
              </button>
            </div>
            <div class="mt-1.5 flex flex-wrap items-center gap-2 px-1">
              <label
                for={@uploads.chat_photos.ref}
                aria-label={gettext("Attach photo")}
                title={gettext("Attach photo")}
                class="press flex size-9 cursor-pointer items-center justify-center rounded-full text-[color:var(--muted)] hover:bg-[var(--sunken)] hover:text-[color:var(--text)]"
              >
                <.icon name="ph-camera" class="size-5" />
              </label>
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
    </Layouts.app>
    """
  end
end
