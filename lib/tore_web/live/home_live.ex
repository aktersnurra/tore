defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Recipes, Planning}
  alias Tore.Pantry.Icons
  alias ToreWeb.PiReply

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    {day, date, cooked} = shown_day(scope)
    week_start = Tore.Streams.monday(date)
    pick = Tore.Home.current(scope)
    if connected?(socket) and pick.stale?, do: Tore.Home.refresh(scope)

    # Tonight follows the plan, whoever changes it: pi asked from here, or anyone elsewhere;
    # and the pantry, so what's at home and the pictures Jev picks show as they change.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tore.PubSub, Planning.topic(scope))
      Phoenix.PubSub.subscribe(Tore.PubSub, Tore.Pantry.topic(scope))
    end

    socket =
      socket
      |> assign(
        day: day,
        date: date,
        cooked: cooked,
        note: note(pick.note, day),
        note_added: false,
        plan_id: Tore.Streams.plan(scope, week_start),
        week_start: week_start,
        day_key: Tore.Streams.slot_key(date),
        tonight_sheet: false,
        before_cooking: false,
        choices: nil,
        changed: nil,
        ticked: %{}
      )
      |> PiReply.init()
      |> reload_tonight()

    # Tonight's ingredients get the pictures Hemma would show, for the list to buy.
    with %{dish: %{recipe_ingredients: [_ | _] = needed}} <- socket.assigns,
         true <- connected?(socket),
         do: Tore.Pantry.Lasts.pictures_later(scope, Enum.map(needed, & &1.ingredient_id))

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <%!-- Plan's width, as Hemma and a recipe page have, so the day-to-day screens feel one. --%>
      <.page max_width={:lg}>
        <%!-- One column, read top to bottom like a status: the dish, when, and whether anything
           needs doing. Side by side it looked like the recipe page. --%>
        <div class="w-full">
          <div class="relative z-10 h-0">
            <%!-- Over the photo, its button sits inside the card's corner. --%>
            <.top_bar
              on_photo={@dish != nil}
              class={["absolute inset-x-0 -top-2", @dish && "inset-x-2 top-0"]}
            />
          </div>

          <%!-- Tonight: the dish is the screen --%>
          <section
            :if={@dish}
            id="tonight-card"
            phx-hook="LongPress"
            data-long-press-event="open_tonight_sheet"
          >
            <%!-- The cover: tonight's photo, or the dish's tinted icon while one is drawn, with
               the dish's name in white on its darkened foot. A rounded card, set in from the
               edges, so the dark foot never meets the page (in light mode it looked cut off).
               Tapping it opens the recipe. --%>
            <.link
              navigate={~p"/recipes?#{[id: @dish.id]}"}
              data-role="cover"
              aria-label={gettext("Open the recipe")}
              class="press press-soft block"
            >
              <div class="relative h-[32svh] min-h-[210px] max-h-[300px] overflow-hidden rounded-[var(--r-xl)]">
                <img
                  :if={photo?(@dish)}
                  src={~p"/images/recipes/#{@dish.id}"}
                  alt=""
                  class="absolute inset-0 size-full rounded-[inherit] object-cover"
                  style={"view-transition-name: dish-#{@dish.id}"}
                />
                <.blank_cover :if={!photo?(@dish)} dish={@dish} icon_class="size-20" />
                <div
                  :if={photo?(@dish)}
                  class="photo-shade absolute inset-0"
                  aria-hidden="true"
                >
                </div>
                <h1
                  class={[
                    "reveal t-display absolute inset-x-0 bottom-0 px-4 pb-4 md:px-5",
                    photo?(@dish) && "on-photo-text"
                  ]}
                  style="--i: 1"
                >
                  {@dish.title}
                </h1>
              </div>
            </.link>

            <div class="min-w-0">
              <.cooked :if={@cooked} title={@cooked} class="mt-4" />

              <%!-- When, in one line: the day, how long, ready by. --%>
              <p
                data-role="when"
                class="reveal num mt-3 text-[color:var(--muted)]"
                style="--i: 2; font-size: 15px;"
              >
                <span class={[
                  "font-semibold",
                  if(@day == :tonight,
                    do: "text-[color:var(--tag-red-ink)]",
                    else: "text-[color:var(--tag-blue-ink)]"
                  )
                ]}>
                  {if @day == :tonight, do: gettext("Tonight"), else: gettext("Tomorrow")}
                </span>
                <span :if={minutes(@dish) > 0}>
                  · {gettext("%{minutes} min", minutes: minutes(@dish))}
                </span>
                <span :if={@day == :tonight and minutes(@dish) > 0 and ready_by(minutes(@dish))}>
                  · {gettext("ready by %{time}", time: ready_by(minutes(@dish)))}
                </span>
              </p>
              <p
                :if={@lunch}
                data-role="lunch"
                class="reveal mt-1 flex items-center gap-2 text-[color:var(--muted)]"
                style="--i: 2; font-size: 15px;"
              >
                <.icon name="ph-bowl-food" class="size-4" />
                {gettext("Lunch")}:
                <.link
                  navigate={~p"/recipes?#{[id: @lunch.id]}"}
                  class="press text-[color:var(--text)] hover:underline"
                >
                  {@lunch.title}
                </.link>
              </p>

              <%!-- Can I start? Tonight with everything at home the answer is Cook now, first
                 and always in the same place. Otherwise what to buy, as Shop lists it, and what
                 Tore isn't sure is still here, as Hemma asks it: a tag for a head, a row each. --%>
              <%!-- Cook now, always here tonight. With something still to buy it first asks what
                 to use instead (Before you start), and can cook anyway. --%>
              <.link
                :if={@day == :tonight and @home.missing == []}
                navigate={~p"/recipes/#{@dish.id}/cook?from=/today"}
                class="pill pill-lamp press reveal mt-5 w-full md:w-auto"
                style="--i: 2"
                data-role="start-cooking"
              >
                <.icon name="ph-fire-fill" /> {gettext("Cook now")}
              </.link>
              <button
                :if={@day == :tonight and @home.missing != []}
                type="button"
                phx-click="before_cooking"
                class="pill pill-lamp press reveal mt-5 w-full md:w-auto"
                style="--i: 2"
                data-role="start-cooking"
              >
                <.icon name="ph-fire-fill" /> {gettext("Cook now")}
              </button>

              <p
                :if={
                  @day == :tomorrow and @dish.recipe_ingredients != [] and @buy == [] and
                    @home.unsure == []
                }
                data-role="ready"
                class="reveal mt-5 flex items-center gap-3"
                style="--i: 2"
              >
                <span class="tag tag-green">
                  <.icon name="ph-check" class="size-3.5" /> {gettext("Everything's at home")}
                </span>
                <.pantry_link />
              </p>

              <%!-- What to buy, ticked off as on Shop: a tick puts it at home (and ticks it on the
                 week's list when it's there); a ticked row stays, and tapping it again undoes it. --%>
              <section :if={@buy != []} data-role="at-home" class="reveal mt-6" style="--i: 2">
                <.group_head
                  id="today-buy"
                  label={gettext("To buy")}
                  tint="red"
                  count={length(@home.missing)}
                />
                <ul id="today-buy" class="pl-6">
                  <li
                    :for={name <- @buy}
                    data-buy={name}
                    class={[
                      "tick-row flex min-h-[44px] items-center gap-3 py-1",
                      Map.has_key?(@ticked, name) && "is-checked"
                    ]}
                  >
                    <button
                      type="button"
                      role="checkbox"
                      aria-checked={to_string(Map.has_key?(@ticked, name))}
                      aria-label={name}
                      phx-click="tick_buy"
                      phx-value-name={name}
                      class="press tick-box"
                    >
                      <svg viewBox="0 0 24 24" aria-hidden="true">
                        <path d="M5.5 12.5l4.2 4.2L18.5 8" />
                      </svg>
                    </button>
                    <button
                      type="button"
                      phx-click="tick_buy"
                      phx-value-name={name}
                      class="press press-soft flex min-w-0 flex-1 items-center gap-3 text-left"
                    >
                      <img
                        src={~p"/images/food/#{Icons.file(picture(@dish, name))}"}
                        alt=""
                        class="size-7 shrink-0"
                      />
                      <span class="tick-name min-w-0 truncate">{name}</span>
                    </button>
                  </li>
                </ul>
              </section>

              <section :if={@home.unsure != []} data-role="unsure" class="reveal mt-4" style="--i: 2">
                <div class="flex items-center justify-between gap-3">
                  <.group_head
                    id="today-unsure"
                    label={gettext("Still there?")}
                    tint="grey"
                    count={length(@home.unsure)}
                  />
                  <.pantry_link />
                </div>
                <ul id="today-unsure" class="pl-6">
                  <li
                    :for={thing <- asked(@home)}
                    data-item={thing.id}
                    class="flex min-h-[52px] items-center gap-3 py-1.5"
                  >
                    <img
                      src={~p"/images/food/#{Icons.file(picture(@dish, thing.name))}"}
                      alt=""
                      class="size-7 shrink-0"
                    />
                    <span class="min-w-0 flex-1">
                      <span class="block truncate">{thing.name}</span>
                      <span
                        :if={thing.last_seen_at}
                        class="num block text-[12.5px] text-[color:var(--muted)]"
                      >
                        {seen_ago(thing.last_seen_at)}
                      </span>
                    </span>
                    <button
                      type="button"
                      phx-click="still_there"
                      phx-value-id={thing.id}
                      data-role="still-there"
                      class="pill press h-8 shrink-0"
                    >
                      {gettext("Still there")}
                    </button>
                    <button
                      type="button"
                      phx-click="gone"
                      phx-value-id={thing.id}
                      data-role="gone"
                      class="pill press h-8 shrink-0"
                    >
                      {gettext("Gone")}
                    </button>
                  </li>
                  <li :if={more(@home) > 0} class="py-1">
                    <.link
                      navigate={~p"/pantry"}
                      class="press text-[color:var(--muted)] hover:text-[color:var(--text)]"
                      style="font-size: 14px;"
                    >
                      {gettext("+%{count} more", count: more(@home))}
                    </.link>
                  </li>
                </ul>
              </section>

              <div class="reveal mt-6 grid grid-cols-2 gap-2 md:flex md:flex-wrap" style="--i: 3">
                <button type="button" phx-click="something_else" class="pill press">
                  <.icon name="ph-arrows-left-right" /> {gettext("Something else")}
                </button>
                <%!-- With something missing, the question about it is already typed. --%>
                <.link
                  navigate={~p"/capture?#{ask_params(@dish, @home)}"}
                  data-role="ask-tore"
                  class="pill press"
                >
                  <.icon name="ph-chat-circle" /> {gettext("Ask Tore")}
                </.link>
              </div>

              <.note :if={@note} note={@note} added={@note_added} class="mt-5" />

              <p
                :if={@changed}
                id="tonight-changed"
                class="settle mt-4 flex items-center gap-3 text-[color:var(--muted)]"
                style="font-size: 15px;"
              >
                <span :if={@changed.from}>{gettext("Instead of %{dish}.", dish: @changed.from)}</span>
                <button
                  type="button"
                  phx-click="undo_tonight"
                  class="press font-semibold text-[color:var(--accent-ink)]"
                >
                  {gettext("Undo")}
                </button>
              </p>

              <PiReply.pi_reply reply={@pi_reply} working={@pi_working} />
            </div>
          </section>

          <%!-- Nothing tonight: say so plainly, and offer the way forward --%>
          <section :if={!@dish} class="pt-20">
            <.cooked :if={@cooked} title={@cooked} class="mb-6" />
            <p class="reveal t-eyebrow num" style="--i: 0">{ToreWeb.Dates.long(@date)}</p>
            <h1 class="reveal t-display mt-2" style="--i: 1">
              {empty_title(@day, @eating_out)}
            </h1>
            <p
              :if={!@eating_out}
              class="reveal mt-3 max-w-[30ch] text-[color:var(--muted)]"
              style="--i: 2; font-size: 15px; line-height: 1.5;"
            >
              {if @day == :tonight,
                do: gettext("Plan the week, or ask Tore what to make tonight."),
                else: gettext("Plan the week, or ask Tore what to make tomorrow.")}
            </p>
            <p :if={@changed} class="settle mt-4 text-[color:var(--muted)]" style="font-size: 15px;">
              <button
                type="button"
                phx-click="undo_tonight"
                class="press font-semibold text-[color:var(--accent-ink)]"
              >
                {gettext("Undo")}
              </button>
            </p>
            <.note :if={@note} note={@note} added={@note_added} class="mt-6" />
            <PiReply.pi_reply reply={@pi_reply} working={@pi_working} />
            <div :if={!@eating_out} class="reveal mt-6 flex flex-wrap gap-2" style="--i: 3">
              <button type="button" phx-click="something_else" class="pill pill-lamp press">
                <.icon name="ph-lightbulb" /> {gettext("Suggest something")}
              </button>
              <.link navigate={~p"/plan"} class="pill press">
                <.icon name="ph-calendar-blank" /> {gettext("Plan the week")}
              </.link>
              <.link navigate={~p"/capture?#{[return_to: "/today"]}"} class="pill press">
                <.icon name="ph-chat-circle" /> {gettext("Ask Tore")}
              </.link>
            </div>
          </section>
        </div>
      </.page>

      <.live_component
        :if={@before_cooking and @dish != nil}
        module={ToreWeb.BeforeCooking}
        id="before-cooking"
        scope={@current_scope}
        recipe={@dish}
        missing={@home.missing}
        cook_params={[from: "/today"]}
        on_close="close_before_cooking"
      />

      <%!-- Something else tonight: a few dishes to choose between, or none --%>
      <.bottom_sheet :if={@choices} id="choices-sheet" on_close="close_choices" class="px-5">
        <p class="t-eyebrow">
          {if @day == :tonight, do: gettext("Tonight"), else: gettext("Tomorrow")}
        </p>
        <p class="t-head mt-1">{gettext("Something else?")}</p>
        <div class="mt-4">
          <ToreWeb.DishChoices.dish_choices
            choices={@choices.list}
            event="choose_tonight"
            loading={@choices.loading}
          />
          <p
            :if={!@choices.loading and @choices.list == []}
            class="py-2 text-[color:var(--muted)]"
            style="font-size: 15px;"
          >
            {gettext("Nothing else in the recipes right now. Ask Tore for an idea.")}
          </p>
        </div>
        <div class="mt-4 flex items-center justify-between border-t border-[color:var(--hairline)] pt-3">
          <button
            :if={@dish}
            type="button"
            phx-click="skip_tonight"
            class="press py-2 text-[color:var(--muted)] hover:text-[color:var(--text)]"
            style="font-size: 15px;"
          >
            {if @day == :tonight,
              do: gettext("No dinner tonight"),
              else: gettext("No dinner tomorrow")}
          </button>
          <.link
            navigate={~p"/capture?#{[return_to: "/today"]}"}
            class="press ml-auto py-2 font-semibold text-[color:var(--text)]"
            style="font-size: 15px;"
          >
            {gettext("Ask Tore")}
          </.link>
        </div>
      </.bottom_sheet>

      <%!-- Anything about tonight, asked in words (Ask, or a long press) --%>
      <.bottom_sheet
        :if={@tonight_sheet && @dish && @day == :tonight}
        id="tonight-sheet"
        on_close="close_tonight_sheet"
        class="px-5"
      >
        <p class="t-eyebrow">{gettext("Tonight")}</p>
        <p class="t-head mt-1">{@dish.title}</p>
        <form phx-submit="tonight_command" class="mt-4">
          <.field
            id="tonight-command"
            name="command"
            autocomplete="off"
            autofocus
            placeholder={gettext("Anything about tonight…")}
            aria-label={gettext("Anything about tonight…")}
            send={gettext("Send")}
            enterkeyhint="send"
          />
        </form>
      </.bottom_sheet>
    </Layouts.app>
    """
  end

  defp change_tonight(socket, change) do
    %{current_scope: scope, plan_id: plan_id, day_key: key, dish: from} =
      socket.assigns

    {:ok, state} = Planning.load_plan(scope, plan_id)
    before = Planning.slots_before(state, [key])
    {:ok, _} = change.(scope, plan_id, key)

    {:noreply,
     socket
     |> reload_tonight()
     |> assign(choices: nil, changed: %{before: before, from: from && from.title})}
  end

  # Tonight, until it's cooked or it's 21:00; then tomorrow, since that's what can still be
  # sorted out this evening. `cooked` is tonight's dish when it was.
  defp shown_day(scope) do
    today = Tore.Clock.today()
    tonight = dish_on(scope, today)
    cooked = tonight && tonight.last_used_at && Tore.Clock.date_of(tonight.last_used_at) == today

    if cooked || Tore.Clock.now().hour >= evening_over(),
      do: {:tomorrow, Date.add(today, 1), cooked && tonight.title},
      else: {:tonight, today, nil}
  end

  # The hour the evening is over, and Today shows tomorrow though tonight wasn't marked cooked.
  defp evening_over, do: Application.get_env(:tore, :evening_over, 21)

  # The pick's note, unless the page already says it: tomorrow's page shows what it needs.
  defp note(%{key: key}, :tomorrow) when key in [:buy_for_tomorrow, :tomorrow_open], do: nil
  defp note(note, _day), do: note

  defp dish_on(scope, date) do
    {:ok, state} = Planning.load_plan(scope, Tore.Streams.plan(scope, Tore.Streams.monday(date)))
    slot = Map.get(state.slots, Tore.Streams.slot_key(date))

    if slot && slot.recipe_id && !slot.skipped,
      do: scope |> Recipes.get_many([slot.recipe_id]) |> List.first()
  end

  # What Fråga asks Tore, in the dish's conversation, about what isn't at home.
  defp ask_missing(missing),
    do:
      gettext(
        "We don't have %{things} at home. What can I use instead, or should I cook something else?",
        things: Enum.join(missing, ", ")
      )

  defp reload_tonight(socket) do
    %{current_scope: scope, plan_id: plan_id, day_key: key} = socket.assigns
    {:ok, state} = Planning.load_plan(scope, plan_id)
    slot = Map.get(state.slots, key)

    tonight =
      if slot && slot.recipe_id && !slot.skipped,
        do: scope |> Recipes.get_many([slot.recipe_id]) |> List.first()

    lunch_id = state.slots[Tore.Streams.slot_key(socket.assigns.date, :lunch)][:recipe_id]

    home =
      tonight &&
        Tore.Pantry.at_home(scope, Enum.map(tonight.recipe_ingredients, & &1.ingredient.name))

    # What to buy: what's missing, and what's been ticked off here, in the recipe's order, so a
    # ticked row keeps its place.
    buy =
      for %{ingredient: %{name: name}} <- (tonight && tonight.recipe_ingredients) || [],
          name in home.missing or Map.has_key?(socket.assigns.ticked, name),
          uniq: true,
          do: name

    assign(socket,
      buy: buy,
      dish: tonight,
      lunch: lunch_id && scope |> Recipes.get_many([lunch_id]) |> List.first(),
      servings: slot && slot[:servings],
      eating_out: Tore.Planning.State.eating_out?(slot),
      home: home
    )
  end

  # The note's things go on the list of the week tomorrow is in.
  def handle_event("add_note_items", _params, %{assigns: %{note: %{things: things}}} = socket) do
    %{current_scope: scope, current_user: user} = socket.assigns
    tomorrow = Date.add(Tore.Clock.today(), 1)
    list_id = Tore.Streams.shop_list(scope, Tore.Streams.monday(tomorrow))
    for name <- things, do: Tore.Shop.add_item(scope, list_id, name, nil, nil, user.id)
    {:noreply, assign(socket, note_added: true)}
  end

  # A few other dishes for tonight, ranked from the library (no model is asked).
  def handle_event("something_else", _params, socket) do
    %{current_scope: scope, plan_id: plan_id, day_key: key, dish: tonight} =
      socket.assigns

    ToreWeb.Background.run(
      fn -> Planning.suggest_recipes_for_slot(scope, plan_id, key, limit: 4) end,
      fn
        {:ok, suggestions} -> {:choices, suggestions}
        _ -> {:choices, []}
      end
    )

    {:noreply,
     assign(socket, choices: %{list: [], loading: true, without: tonight && tonight.id})}
  end

  def handle_event("close_choices", _params, socket), do: {:noreply, assign(socket, choices: nil)}

  # Cook now, when something isn't at home: first the sheet that asks about it.
  def handle_event("before_cooking", _params, socket),
    do: {:noreply, assign(socket, before_cooking: true)}

  def handle_event("close_before_cooking", _params, socket),
    do: {:noreply, assign(socket, before_cooking: false)}

  # Tonight becomes the chosen dish, for the servings it had; Undo puts tonight back.
  def handle_event("choose_tonight", %{"id" => id}, socket) do
    change_tonight(socket, fn scope, plan_id, key ->
      Planning.assign_recipe(
        scope,
        plan_id,
        key,
        String.to_integer(id),
        socket.assigns.servings || 4
      )
    end)
  end

  def handle_event("skip_tonight", _params, socket) do
    change_tonight(socket, fn scope, plan_id, key -> Planning.skip_meal(scope, plan_id, key) end)
  end

  def handle_event("undo_tonight", _params, %{assigns: %{changed: %{} = changed}} = socket) do
    :ok =
      Planning.restore_slots(socket.assigns.current_scope, socket.assigns.plan_id, changed.before)

    {:noreply, socket |> reload_tonight() |> assign(changed: nil)}
  end

  def handle_event("open_tonight_sheet", _params, socket) do
    if socket.assigns.dish do
      {:noreply, assign(socket, tonight_sheet: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_tonight_sheet", _params, socket) do
    {:noreply, assign(socket, tonight_sheet: false)}
  end

  def handle_event("tonight_command", %{"command" => command}, socket) when command != "" do
    %{dish: dish, date: date, day: day} = socket.assigns
    which = if day == :tomorrow, do: "tomorrow's", else: "tonight's"

    message =
      "From the Today screen, about #{which} dinner (#{dish && dish.title}, " <>
        "#{Date.to_iso8601(date)}): #{command}"

    {:noreply,
     socket
     |> assign(tonight_sheet: false)
     |> PiReply.ask(message, gettext("Changing the plan…"))}
  end

  def handle_event("tonight_command", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_pi_reply", _params, socket), do: {:noreply, PiReply.dismiss(socket)}

  # Ticked off: bought, so at home; on the week's list it's ticked there too, as on Shop. Tapping
  # again undoes both.
  def handle_event("tick_buy", %{"name" => name}, socket) do
    ticked =
      case Map.fetch(socket.assigns.ticked, name) do
        {:ok, ticked} ->
          :ok = untick(socket, name, ticked)
          Map.delete(socket.assigns.ticked, name)

        :error ->
          Map.put(socket.assigns.ticked, name, tick(socket, name))
      end

    {:noreply, socket |> assign(ticked: ticked) |> reload_tonight()}
  end

  # Something Tore was unsure of: still there makes it sure, gone puts it with what's missing.
  def handle_event("still_there", %{"id" => id}, socket) do
    {:ok, _item} = Tore.Pantry.confirm_item(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, reload_tonight(socket)}
  end

  def handle_event("gone", %{"id" => id}, socket) do
    {:ok, _item} = Tore.Pantry.mark_gone(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, reload_tonight(socket)}
  end

  def handle_info({:choices, suggestions}, %{assigns: %{choices: %{} = choices}} = socket) do
    list = suggestions |> Enum.reject(&(&1.recipe.id == choices.without)) |> Enum.take(3)
    {:noreply, assign(socket, choices: %{choices | list: list, loading: false})}
  end

  def handle_info({:choices, _suggestions}, socket), do: {:noreply, socket}

  def handle_info({:events, _events}, socket), do: {:noreply, reload_tonight(socket)}
  def handle_info(:pantry_changed, socket), do: {:noreply, reload_tonight(socket)}

  def handle_info({:pi, _session, event}, socket) do
    if socket.assigns.before_cooking, do: ToreWeb.BeforeCooking.forward(event)
    {:noreply, PiReply.event(socket, event)}
  end

  attr :note, :map, required: true
  attr :added, :boolean, required: true
  attr :class, :string, default: nil

  # The one thing worth a glance now, as the home pick chose it, with what to do about it.
  defp note(assigns) do
    ~H"""
    <p
      class={["settle flex flex-wrap items-center gap-x-3 gap-y-1", @class]}
      style="font-size: 15px;"
      data-role="note"
      data-note={@note.key}
    >
      <.icon name={note_icon(@note.key)} class="size-5 text-[color:var(--muted)]" />
      <span class="text-[color:var(--text)]">{note_text(@note)}</span>
      <button
        :if={@note.key == :buy_for_tomorrow and !@added}
        type="button"
        phx-click="add_note_items"
        class="press font-semibold text-[color:var(--accent-ink)] hover:underline"
      >
        {gettext("Put on the list")}
      </button>
      <.link
        :if={@note.key == :buy_for_tomorrow and @added}
        navigate={~p"/shop"}
        class="settle inline-flex items-center gap-1 font-semibold text-[color:var(--done)]"
      >
        <.icon name="ph-check" class="size-4" /> {gettext("On the list")}
      </.link>
      <.link
        :if={@note.key == :shop_now}
        navigate={~p"/shop"}
        class="press font-semibold text-[color:var(--accent-ink)] hover:underline"
      >
        {gettext("Open the list")}
      </.link>
      <.link
        :if={@note.key == :tomorrow_open}
        navigate={~p"/plan"}
        class="press font-semibold text-[color:var(--accent-ink)] hover:underline"
      >
        {gettext("Plan it")}
      </.link>
    </p>
    """
  end

  defp note_icon(:buy_for_tomorrow), do: "ph-basket"
  defp note_icon(:shop_now), do: "ph-shopping-cart"
  defp note_icon(:tomorrow_open), do: "ph-calendar-blank"

  defp note_text(%{key: :buy_for_tomorrow, things: things}),
    do: gettext("Buy %{things} before tomorrow", things: and_list(things))

  defp note_text(%{key: :shop_now, count: count}),
    do: ngettext("One thing on the list", "%{count} things on the list", count)

  defp note_text(%{key: :tomorrow_open}), do: gettext("Tomorrow's dinner isn't planned yet")

  # "lax", "lax and dill", "lax, dill and lime".
  defp and_list([one]), do: one

  defp and_list(things) do
    {rest, [last]} = Enum.split(things, -1)
    gettext("%{rest} and %{last}", rest: Enum.join(rest, ", "), last: last)
  end

  attr :title, :string, required: true
  attr :class, :string, default: nil

  # Tonight's dinner, done: one quiet line above tomorrow.
  defp cooked(assigns) do
    ~H"""
    <p
      class={["flex items-center gap-2 text-[color:var(--muted)]", @class]}
      style="font-size: 15px;"
      data-role="cooked"
    >
      <.icon name="ph-check-circle" class="size-5 text-[color:var(--done)]" />
      {gettext("%{dish}, cooked tonight", dish: @title)}
    </p>
    """
  end

  defp empty_title(:tonight, true), do: gettext("Eating out tonight")
  defp empty_title(:tonight, _eating_out), do: gettext("Tonight is open")
  defp empty_title(:tomorrow, true), do: gettext("Eating out tomorrow")
  defp empty_title(:tomorrow, _eating_out), do: gettext("Tomorrow is open")

  defp photo?(recipe), do: recipe != nil and recipe.image_path != nil

  defp minutes(recipe), do: (recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0)

  # Today asks about this many things it's unsure of; the rest wait on Hemma.
  @ask_at_most 3

  defp asked(home), do: Enum.take(home.unsure, @ask_at_most)
  defp more(home), do: max(length(home.unsure) - @ask_at_most, 0)

  # When an unsure thing was last bought or seen, as a person says it.
  defp seen_ago(%DateTime{} = seen) do
    case Date.diff(Tore.Clock.today(), DateTime.to_date(seen)) do
      days when days <= 1 -> gettext("last seen yesterday")
      days -> gettext("last seen %{count} days ago", count: days)
    end
  end

  attr :rest, :global

  # Hemma, from the card that says what's at home.
  defp pantry_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/pantry"}
      data-role="to-pantry"
      class="press flex items-center gap-1 text-[color:var(--muted)] hover:text-[color:var(--text)]"
      style="font-size: 14px;"
    >
      {gettext("At home")} <.icon name="ph-caret-right" class="size-3.5" />
    </.link>
    """
  end

  # Ticks `name` on the week's list when it's there unticked (which puts it away, as on Shop), or
  # puts it away; answers what undoing it needs: the list's item it ticked, if any, and whether
  # the pantry had a row for it before.
  defp tick(socket, name) do
    %{current_scope: scope, current_user: user, week_start: week_start} = socket.assigns
    kept_before = Tore.Pantry.kept?(scope, name)
    list_id = Tore.Streams.shop_list(scope, week_start)
    key = Tore.Recipes.Ingredient.to_key(name)
    {:ok, %{items: items}} = Tore.Shop.load_list(scope, list_id)

    case Enum.find(items, fn {_id, item} ->
           !item.checked and Tore.Recipes.Ingredient.to_key(item.name) == key
         end) do
      {id, _item} ->
        {:ok, _} = Tore.Shop.check_item(scope, list_id, id, user.id)
        %{on_list: {list_id, id}, kept_before: kept_before}

      nil ->
        {:ok, _} = Tore.Pantry.put_away(scope, name, nil, nil)
        %{on_list: nil, kept_before: kept_before}
    end
  end

  defp untick(socket, name, %{on_list: on_list, kept_before: kept_before}) do
    %{current_scope: scope, current_user: user} = socket.assigns

    with {list_id, id} <- on_list,
         do: {:ok, _} = Tore.Shop.uncheck_item(scope, list_id, id, user.id)

    Tore.Pantry.not_bought(scope, name, kept_before)
  end

  # When dinner is ready if it's started now: only when it could be (from the afternoon until
  # the evening's over), since "ready 00:57" says nothing.
  defp ready_by(minutes) do
    now = Tore.Clock.now()

    if now.hour >= cooking_from() and now.hour < evening_over(),
      do: now |> NaiveDateTime.add(minutes, :minute) |> Calendar.strftime("%H:%M")
  end

  defp cooking_from, do: Application.get_env(:tore, :cooking_from, 15)

  # The picture of one of tonight's ingredients, as Hemma shows it.
  defp picture(dish, name) do
    key = Tore.Recipes.Ingredient.to_key(name)

    ingredient =
      Enum.find_value(dish.recipe_ingredients, &(&1.ingredient.key == key && &1.ingredient))

    Icons.shown(ingredient && ingredient.icon, ingredient && ingredient.category)
  end

  # Fråga Tore opens the dish's conversation; with something missing, the question is typed.
  defp ask_params(dish, home) do
    [return_to: "/today", recipe: dish.id] ++
      if home.missing != [], do: [q: ask_missing(home.missing)], else: []
  end
end
