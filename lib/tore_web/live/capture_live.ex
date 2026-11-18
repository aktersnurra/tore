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
        input: params["q"] || "",
        loading: false,
        working: nil,
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

  # The missing things from a "can I make it" card go on this week's list.
  def handle_event("add_missing", %{"index" => index}, socket) do
    index = String.to_integer(index)
    %{current_scope: scope, current_user: user} = socket.assigns
    list_id = Tore.Streams.shop_list(scope, Tore.Streams.monday(Tore.Clock.today()))

    case Enum.at(socket.assigns.messages, index) do
      %{can_make: %{missing: missing} = can_make, added: nil} ->
        for name <- missing,
            !swapped?(can_make, name),
            do: Tore.Shop.add_item(scope, list_id, name, nil, nil, user.id)

        {:noreply,
         update(socket, :messages, &List.update_at(&1, index, fn m -> %{m | added: true} end))}

      _ ->
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

      view = self()

      ctx = %{
        scope: socket.assigns.current_scope,
        progress: &send(view, {:route_step, &1})
      }

      ToreWeb.Background.run(
        fn -> Router.route(text, images, ctx, history) end,
        &{:route_complete, &1}
      )

      {:noreply,
       assign(socket,
         messages: messages,
         input: "",
         loading: true,
         working: first_step(text, images)
       )}
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

  # A card that can be acted on keeps whether it has been.
  defp actionable(%{can_make: _} = bubble), do: Map.put(bubble, :added, nil)
  defp actionable(bubble), do: bubble

  attr :msg, :map, required: true
  attr :index, :integer, required: true

  # Whether a dish can be made now: its photo, what's missing, and the two ways on.
  defp can_make(assigns) do
    ~H"""
    <div
      data-role="can-make"
      class="rise-in w-full max-w-[85%] rounded-[20px] rounded-bl-md bg-[var(--sunken)] p-3"
    >
      <div class="flex items-center gap-3">
        <span class="relative size-16 shrink-0 overflow-hidden rounded-[var(--r-md)]">
          <img
            :if={@msg.can_make.photo}
            src={~p"/images/recipes/#{@msg.can_make.recipe_id}"}
            alt=""
            class="size-full object-cover"
          />
          <.blank_cover
            :if={!@msg.can_make.photo}
            dish={
              %{
                title: @msg.can_make.title,
                recipe_type: if(@msg.can_make.baking, do: :baking, else: :meal)
              }
            }
            icon_class="size-8"
          />
        </span>
        <div class="min-w-0 flex-1">
          <p class="truncate text-[16px] font-semibold text-[color:var(--text)]">
            {@msg.can_make.title}
          </p>
          <p
            :if={@msg.can_make.missing == []}
            class="mt-0.5 flex items-center gap-1 text-[14px] font-semibold text-[color:var(--done)]"
          >
            <.icon name="ph-check" class="size-4" /> {gettext("All of it is at home")}
          </p>
          <p
            :if={@msg.can_make.missing != [] and !@msg.can_make[:swaps]}
            class="mt-0.5 text-[14px] text-[color:var(--muted)]"
          >
            {gettext("Missing: %{things}", things: Enum.join(@msg.can_make.missing, ", "))}
          </p>
        </div>
      </div>
      <ul :if={@msg.can_make[:swaps]} class="mt-3 space-y-1.5" data-role="swaps">
        <li :for={swap <- @msg.can_make.swaps} class="text-[14px] leading-snug">
          <span class="text-[color:var(--muted)]">{swap.for}</span>
          <span :if={swap.use} class="font-semibold text-[color:var(--text)]">
            <.icon name="ph-arrow-right" class="size-3.5" /> {swap.use}
          </span>
          <span :if={swap.at_home} class="tag tag-green">{gettext("At home")}</span>
          <span :if={swap.note} class="block text-[color:var(--muted)]">{swap.note}</span>
          <span :if={!swap.use and !swap.note} class="block text-[color:var(--muted)]">
            {gettext("Nothing at home fits.")}
          </span>
        </li>
      </ul>
      <div class="mt-3 flex flex-wrap items-center gap-2">
        <.link
          :if={@msg.can_make.recipe_id}
          navigate={cook_path(@msg.can_make)}
          class={[
            "pill press",
            Enum.all?(@msg.can_make.missing, &swapped?(@msg.can_make, &1)) && "pill-lamp"
          ]}
        >
          <.icon name="ph-play" />
          {if @msg.can_make.baking, do: gettext("Bake now"), else: gettext("Cook now")}
        </.link>
        <button
          :if={!@msg.added and Enum.any?(@msg.can_make.missing, &(!swapped?(@msg.can_make, &1)))}
          type="button"
          phx-click="add_missing"
          phx-value-index={@index}
          class="pill pill-lamp press"
        >
          <.icon name="ph-plus" /> {gettext("Put what's missing on the list")}
        </button>
        <.link
          :if={@msg.added}
          id={"added-#{@index}"}
          navigate={~p"/shop"}
          class="settle inline-flex items-center gap-1 text-[14px] font-semibold text-[color:var(--done)]"
        >
          <.icon name="ph-check" class="size-4" /> {gettext("On the list")}
        </.link>
      </div>
    </div>
    """
  end

  # A missing thing with something to use instead doesn't need buying.
  defp swapped?(can_make, name),
    do: Enum.any?(can_make[:swaps] || [], &(&1.for == name and &1.use))

  defp cook_path(%{recipe_id: id} = can_make) do
    swaps = Enum.filter(can_make[:swaps] || [], & &1.use)
    ~p"/recipes/#{id}/cook?#{ToreWeb.BeforeCooking.to_param(swaps)}"
  end

  # A reply meant only for the model, such as a rejected memory batch, has no text.
  defp shown(bubbles), do: Enum.reject(bubbles, &(&1.role == :assistant and &1[:text] == ""))

  # What Tore is doing, named as the kitchen would: before any tool runs, and as each starts.
  defp first_step(_text, [_ | _]), do: gettext("Reading the photo…")

  defp first_step(text, []) do
    if text =~ ~r{https?://},
      do: gettext("Reading the link…"),
      else: gettext("Checking the kitchen…")
  end

  defp step_label(names), do: Enum.find_value(names, &step_label_for/1)

  defp step_label_for("ingest_receipt"), do: gettext("Reading the receipt…")

  defp step_label_for(n) when n in ~w(ingest_recipe import_recipe_from_url),
    do: gettext("Reading the recipe…")

  defp step_label_for(n) when n in ~w(update_pantry_from_shelf suggest_from_fridge),
    do: gettext("Reading the photo…")

  defp step_label_for("find_recipe"), do: gettext("Looking through the recipes…")

  defp step_label_for(n) when n in ~w(can_i_make check_pantry),
    do: gettext("Checking what's at home…")

  defp step_label_for("suggest_meals_from_pantry"), do: gettext("Finding dinners…")
  defp step_label_for("plan_week"), do: gettext("Planning the week…")

  defp step_label_for(n)
       when n in ~w(set_plan_slot clear_plan_slot skip_plan_meal set_plan_servings pin_plan_slot mark_eating_out),
       do: gettext("Changing the plan…")

  defp step_label_for("generate_shopping_list_from_plan"), do: gettext("Making the list…")

  defp step_label_for(n)
       when n in ~w(add_to_shopping_list check_off_shopping_item remove_shopping_item list_shopping_list),
       do: gettext("Going through the list…")

  defp step_label_for(_name), do: nil

  @impl true
  def handle_info({:route_step, names}, socket) do
    {:noreply, assign(socket, working: step_label(names) || socket.assigns.working)}
  end

  def handle_info({:quick_swaps, swaps}, socket), do: {:noreply, assign(socket, swaps: swaps)}

  def handle_info({:route_complete, {:ok, bubbles}}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(working: nil)
     |> update(:messages, &(&1 ++ Enum.map(shown(bubbles), fn b -> actionable(b) end)))}
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
          <.icon name="ph-x" class="size-5" />
        </.link>
      </div>

      <div id="chat-messages" class="flex-1 overflow-y-auto px-4 py-4 space-y-3">
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
          :for={{msg, index} <- Enum.with_index(@messages)}
          class={[
            "flex",
            msg.role == :user && "justify-end",
            msg.role == :assistant && "justify-start"
          ]}
        >
          <div
            :if={Map.get(msg, :pantry_suggestions)}
            class="rise-in w-full max-w-[85%] space-y-2"
          >
            <p class="rounded-[20px] rounded-bl-md bg-[var(--sunken)] px-4 py-2.5 text-[15px] text-[color:var(--text)]">
              {msg.text}
            </p>
            <ul class="space-y-1">
              <li :for={s <- msg.suggestions}>
                <.link
                  navigate={~p"/recipes?#{[id: s.recipe_id]}"}
                  class="row-hover press-soft flex items-center gap-3 rounded-[var(--r-lg)] p-1.5"
                >
                  <span class="relative size-14 shrink-0 overflow-hidden rounded-[var(--r-md)]">
                    <img
                      :if={s[:photo]}
                      src={~p"/images/recipes/#{s.recipe_id}"}
                      alt=""
                      loading="lazy"
                      class="size-full object-cover"
                    />
                    <.blank_cover :if={!s[:photo]} dish={s} icon_class="size-7" />
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-[15px] font-semibold text-[color:var(--text)]">
                      {s.title}
                    </span>
                    <span
                      :if={s.reasons != []}
                      class="block truncate text-[13px] text-[color:var(--muted)]"
                    >
                      {hd(s.reasons)}
                    </span>
                  </span>
                </.link>
              </li>
            </ul>
          </div>
          <.can_make :if={Map.get(msg, :can_make)} msg={msg} index={index} />
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
            :if={
              !Map.get(msg, :pantry_suggestions) && !Map.get(msg, :shop_link) &&
                !Map.get(msg, :can_make)
            }
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
