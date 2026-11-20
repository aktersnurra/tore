defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Recipes, Planning}
  alias ToreWeb.PiReply

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    {day, date, cooked} = shown_day(scope)
    week_start = Tore.Streams.monday(date)
    pick = Tore.Home.current(scope)
    if connected?(socket) and pick.stale?, do: Tore.Home.refresh(scope)

    # Tonight follows the plan, whoever changes it: pi asked from here, or anyone elsewhere.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Tore.PubSub, Planning.topic(scope))

    {:ok,
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
       changed: nil
     )
     |> PiReply.init()
     |> reload_tonight()}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:xl}>
        <%!-- A phone's column, until a laptop has room for the dish beside its details. --%>
        <div class="mx-auto w-full max-w-md lg:max-w-none">
          <div class="relative z-10 h-0">
            <%!-- Over the photo, its buttons sit inside the card's corners. --%>
            <.top_bar
              on_photo={@dish != nil}
              class={["absolute inset-x-0 -top-2", @dish && "max-lg:inset-x-2 max-lg:top-0"]}
            >
              <:actions :if={@dish}>
                <.page_menu id="today-menu" on_photo>
                  <.menu_item
                    menu="today-menu"
                    icon="ph-book-open"
                    navigate={~p"/recipes?#{[id: @dish.id]}"}
                  >
                    {gettext("Open the recipe")}
                  </.menu_item>
                  <.menu_item
                    :if={@day == :tonight}
                    menu="today-menu"
                    icon="ph-chat-circle"
                    event="open_tonight_sheet"
                  >
                    {gettext("Ask about tonight")}
                  </.menu_item>
                  <.menu_item menu="today-menu" icon="ph-x-circle" event="skip_tonight">
                    {if @day == :tonight,
                      do: gettext("No dinner tonight"),
                      else: gettext("No dinner tomorrow")}
                  </.menu_item>
                </.page_menu>
              </:actions>
            </.top_bar>
          </div>

          <%!-- Tonight: the dish is the screen --%>
          <section
            :if={@dish}
            id="tonight-card"
            phx-hook="LongPress"
            data-long-press-event="open_tonight_sheet"
            class="lg:grid lg:grid-cols-2 lg:items-start lg:gap-14 lg:pt-14"
          >
            <%!-- The cover: tonight's photo, or the dish's tinted icon while one is drawn, with
               the dish's name in white on its darkened foot. A rounded card, set in from the
               edges, so the dark foot never meets the page (in light mode it looked cut off). On a laptop it's the whole picture
               on the right, as on a recipe page, and the name moves to the left: no words on
               the picture, so no shade either. --%>
            <div class="lg:sticky lg:top-6 lg:order-2">
              <div class="relative h-[32svh] min-h-[210px] max-h-[300px] overflow-hidden rounded-[var(--r-xl)] lg:aspect-[5/4] lg:h-auto lg:max-h-none">
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
                  class="photo-shade absolute inset-0 lg:hidden"
                  aria-hidden="true"
                >
                </div>
                <h1
                  class={[
                    "reveal t-display absolute inset-x-0 bottom-0 px-4 pb-4 md:px-5 lg:hidden",
                    photo?(@dish) && "on-photo-text"
                  ]}
                  style="--i: 1"
                >
                  {@dish.title}
                </h1>
              </div>
            </div>

            <div class="min-w-0">
              <h1 class="reveal t-hero hidden lg:block" style="--i: 1">{@dish.title}</h1>
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
                <span :if={@day == :tonight and minutes(@dish) > 0}>
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

              <%!-- Can I start? What Today answers first: everything's here, or what to buy
                 first, and what Tore isn't sure is still here, asked right there. --%>
              <div
                :if={@dish.recipe_ingredients != []}
                class="menu-lines reveal mt-5"
                style="--i: 2"
              >
                <div
                  :if={@home.missing == [] and @home.unsure == []}
                  data-role="ready"
                  class="flex items-center gap-3 py-3.5"
                >
                  <.icon name="ph-check-circle-fill" class="size-5 text-[color:var(--done)]" />
                  <span class="flex-1 font-semibold" style="font-size: 16px;">
                    {gettext("Everything's at home")}
                  </span>
                  <.pantry_link />
                </div>

                <div :if={@home.missing != []} data-role="at-home" class="py-3">
                  <div class="flex items-center gap-3">
                    <.icon name="ph-shopping-cart" class="size-5 text-[color:var(--danger)]" />
                    <span class="flex-1 font-semibold" style="font-size: 16px;">
                      {gettext("Shop first")}
                    </span>
                    <.pantry_link />
                  </div>
                  <div class="mt-2 flex flex-wrap items-center gap-1.5 pl-8">
                    <span class="sr-only">
                      {gettext("Missing: %{things}", things: Enum.join(@home.missing, ", "))}
                    </span>
                    <span :for={thing <- @home.missing} class="tag tag-red" aria-hidden="true">
                      {thing}
                    </span>
                    <button
                      :if={!@home_added}
                      type="button"
                      phx-click="add_missing"
                      class="press ml-1 text-[color:var(--muted)] underline decoration-[color:var(--subtle)] underline-offset-4 hover:text-[color:var(--text)]"
                      style="font-size: 14px;"
                    >
                      {gettext("Put on the list")}
                    </button>
                    <.link
                      :if={@home_added}
                      id="home-added"
                      navigate={~p"/shop"}
                      class="settle ml-1 inline-flex items-center gap-1 font-semibold text-[color:var(--done)]"
                      style="font-size: 14px;"
                    >
                      <.icon name="ph-check" class="size-4" /> {gettext("On the list")}
                    </.link>
                  </div>
                </div>

                <div :if={@home.unsure != []} data-role="unsure" class="py-3">
                  <div class="flex items-center gap-3">
                    <.icon name="ph-warning-circle" class="size-5 text-[color:var(--muted)]" />
                    <span class="flex-1 font-semibold" style="font-size: 16px;">
                      {gettext("Still there?")}
                    </span>
                  </div>
                  <ul class="mt-1 pl-8">
                    <li
                      :for={thing <- asked(@home)}
                      data-item={thing.id}
                      class="flex items-center gap-2 py-1.5"
                    >
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
                        class="pill press h-8"
                      >
                        {gettext("Still there")}
                      </button>
                      <button
                        type="button"
                        phx-click="gone"
                        phx-value-id={thing.id}
                        data-role="gone"
                        class="pill press h-8"
                      >
                        {gettext("Gone")}
                      </button>
                    </li>
                  </ul>
                  <.link
                    :if={more(@home) > 0}
                    navigate={~p"/pantry"}
                    class="press ml-8 mt-1 inline-block text-[color:var(--muted)] hover:text-[color:var(--text)]"
                    style="font-size: 14px;"
                  >
                    {gettext("+%{count} more", count: more(@home))}
                  </.link>
                </div>
              </div>

              <%!-- On a phone the main action is the width of the page, the others a row under it. --%>
              <div
                class="reveal mt-5 grid grid-cols-2 gap-2 lg:flex lg:flex-wrap [&>:first-child]:col-span-2 [&>:nth-child(2):last-child]:col-span-2"
                style="--i: 3"
              >
                <.link
                  :if={@day == :tomorrow}
                  navigate={~p"/recipes?#{[id: @dish.id]}"}
                  class="pill press"
                  data-role="open-recipe"
                >
                  <.icon name="ph-book-open" /> {gettext("Open the recipe")}
                </.link>
                <.link
                  :if={@day == :tonight and @home.missing == []}
                  navigate={~p"/recipes/#{@dish.id}/cook?from=/today"}
                  class="pill pill-lamp press"
                  data-role="start-cooking"
                >
                  <.icon name="ph-fire-fill" /> {gettext("Cook now")}
                </.link>
                <button
                  :if={@day == :tonight and @home.missing != []}
                  type="button"
                  phx-click="before_cooking"
                  class="pill pill-lamp press"
                  data-role="start-cooking"
                >
                  <.icon name="ph-fire-fill" /> {gettext("Cook now")}
                </button>
                <button type="button" phx-click="something_else" class="pill press">
                  <.icon name="ph-arrows-left-right" /> {gettext("Something else")}
                </button>
                <.link
                  navigate={~p"/capture?#{[return_to: "/today", recipe: @dish.id]}"}
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

              <section :if={@dish.recipe_ingredients != []} class="reveal mt-8" style="--i: 4">
                <h2 class="t-head mb-1">{gettext("Ingredients")}</h2>
                <ul class="menu-lines">
                  <li
                    :for={ri <- @dish.recipe_ingredients}
                    class="flex items-baseline justify-between gap-4 py-3"
                  >
                    <span class="text-[color:var(--text)]" style="font-size: 16px;">
                      {ri.ingredient.name}
                    </span>
                    <span class="num shrink-0 text-[color:var(--muted)]" style="font-size: 15px;">
                      {amount(ri, @dish.base_servings, @servings)}
                    </span>
                  </li>
                </ul>
              </section>
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
            {gettext("No dinner tonight")}
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

    list_id = Tore.Streams.shop_list(scope, socket.assigns.week_start)

    assign(socket,
      dish: tonight,
      lunch: lunch_id && scope |> Recipes.get_many([lunch_id]) |> List.first(),
      servings: slot && slot[:servings],
      eating_out: Tore.Planning.State.eating_out?(slot),
      home: home,
      # Already on the list when there's nothing left to put there.
      home_added: home != nil and Tore.Shop.not_on_list(scope, list_id, home.missing) == []
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

  # What tonight needs and the house doesn't have goes on this week's list.
  def handle_event("add_missing", _params, %{assigns: %{home_added: false, home: %{}}} = socket) do
    %{current_scope: scope, current_user: user, home: home, week_start: monday} = socket.assigns
    list_id = Tore.Streams.shop_list(scope, monday)
    for name <- home.missing, do: Tore.Shop.add_item(scope, list_id, name, nil, nil, user.id)
    {:noreply, assign(socket, home_added: true)}
  end

  def handle_event("add_missing", _params, socket), do: {:noreply, socket}

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

  defp amount(ri, base, servings) do
    quantity = Recipes.scale_quantity(ri.quantity, base, servings || base)
    unit = if ri.unit not in [nil, ""], do: " #{ri.unit}"
    "#{quantity}#{unit}"
  end

  defp ready_by(minutes),
    do: Tore.Clock.now() |> NaiveDateTime.add(minutes, :minute) |> Calendar.strftime("%H:%M")
end
