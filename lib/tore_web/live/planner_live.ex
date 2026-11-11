defmodule ToreWeb.PlannerLive do
  use ToreWeb, :live_view

  on_mount {ToreWeb.Live.Auth, :hears_runs}

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds.PlannerCommand

  alias Tore.{Recipes, Planning, PlanHealth}
  alias Tore.Planning.State
  alias Phoenix.PubSub

  @days ~w[mon tue wed thu fri sat sun]

  def mount(_params, _session, socket) do
    today = Tore.Clock.today()
    week_start = Tore.Streams.monday(today)
    scope = socket.assigns.current_scope
    plan_id = plan_id(scope, week_start)

    if connected?(socket) do
      # Run changes come through ToreWeb.Live.Auth, which subscribes for every view.
      PubSub.subscribe(Tore.PubSub, Tore.Planning.topic(scope))
    end

    {:ok, plan_state} = Planning.load_plan(scope, plan_id)
    recipes = Recipes.list(scope, sort: :alphabetical)
    current_run = Runs.latest_on_surface(scope, :plan)

    {:ok,
     assign(socket,
       today: today,
       week_start: week_start,
       plan_id: plan_id,
       plan_state: plan_state,
       recipes: recipes,
       slot_action: nil,
       plan_health: PlanHealth.compute(plan_state),
       current_week_mode: Tore.WeekMode.get_current_mode(scope),
       current_run: current_run,
       quick_loading: false,
       focused_slots: MapSet.new()
     )}
  end

  def handle_params(params, _uri, socket) do
    slots =
      case params["focus"] do
        f when is_binary(f) and f != "" -> f |> String.split(",", trim: true) |> MapSet.new()
        _ -> MapSet.new()
      end

    {:noreply, assign(socket, focused_slots: slots)}
  end

  def handle_event("prev_week", _params, socket) do
    week_start = Date.add(socket.assigns.week_start, -7)
    {:noreply, load_week(socket, week_start)}
  end

  def handle_event("next_week", _params, socket) do
    week_start = Date.add(socket.assigns.week_start, 7)
    {:noreply, load_week(socket, week_start)}
  end

  def handle_event("open_slot", %{"slot_key" => sk}, socket) do
    slot = Map.get(socket.assigns.plan_state.slots, sk)

    # Find which future slots are already marked as leftovers from this slot's recipe
    existing_leftover_days =
      if slot && slot.recipe_id do
        socket.assigns.plan_state.slots
        |> Enum.filter(fn {k, s} -> k != sk && s.leftover && s.recipe_id == slot.recipe_id end)
        |> Enum.map(fn {k, _} -> k end)
        |> MapSet.new()
      else
        MapSet.new()
      end

    initial = %{
      slot_key: sk,
      search: "",
      suggestions: [],
      loading_suggestions: true,
      selected_recipe_id: slot && slot.recipe_id,
      servings: (slot && slot.servings) || 4,
      leftover_days: existing_leftover_days,
      # Eating out is its own state, and picking a recipe replaces it.
      skipped: (slot && slot.skipped && !State.eating_out?(slot)) || false,
      eating_out: State.eating_out?(slot),
      eating_out_open: State.eating_out?(slot),
      dining: State.eating_out?(slot) && %{place: slot[:place], amount: slot[:amount]},
      flipped: false,
      pinned: Map.has_key?(socket.assigns.plan_state.pins, sk)
    }

    %{plan_id: plan_id, current_scope: scope} = socket.assigns

    dietary_guidance =
      Tore.Household.get_preferences(scope) |> Tore.Household.prefs_to_dietary_guidance()

    ToreWeb.Background.run(
      fn ->
        Planning.suggest_recipes_for_slot(scope, plan_id, sk,
          limit: 5,
          dietary_guidance: dietary_guidance
        )
      end,
      fn
        {:ok, suggestions} -> {:suggestions_loaded, sk, suggestions}
        _ -> {:suggestions_loaded, sk, []}
      end
    )

    {:noreply, assign(socket, slot_action: Map.put(initial, :saved, slot_choice(initial)))}
  end

  def handle_event("flip_slot", _, socket) do
    {:noreply, update_slot(socket, fn s -> %{s | flipped: !s.flipped, search: ""} end)}
  end

  def handle_event("close_slot", _params, socket) do
    # Auto-save pending state before closing
    socket = auto_save_slot(socket)
    {:noreply, assign(socket, slot_action: nil)}
  end

  def handle_event("search_slot_recipes", %{"q" => q}, socket) do
    {:noreply, update_slot(socket, fn s -> %{s | search: q} end)}
  end

  def handle_event("pick_recipe", %{"id" => rid}, socket) do
    rid = String.to_integer(rid)
    recipe = Enum.find(socket.assigns.recipes, &(&1.id == rid))

    socket =
      update_slot(socket, fn s ->
        %{
          s
          | selected_recipe_id: rid,
            servings: (recipe && recipe.base_servings) || s.servings || 4,
            flipped: false
        }
      end)

    # Auto-save immediately on recipe pick
    socket = auto_save_slot(socket)
    {:noreply, socket}
  end

  def handle_event("inc_servings", _, socket) do
    {:noreply, update_slot(socket, fn s -> %{s | servings: min((s.servings || 1) + 1, 12)} end)}
  end

  def handle_event("dec_servings", _, socket) do
    {:noreply, update_slot(socket, fn s -> %{s | servings: max((s.servings || 1) - 1, 1)} end)}
  end

  def handle_event("toggle_leftover_day", %{"day" => d}, socket) do
    socket =
      update_slot(socket, fn s ->
        new =
          if MapSet.member?(s.leftover_days, d),
            do: MapSet.delete(s.leftover_days, d),
            else: MapSet.put(s.leftover_days, d)

        %{s | leftover_days: new}
      end)

    {:noreply, auto_save_slot(socket)}
  end

  def handle_event("toggle_skipped", _, socket) do
    socket = update_slot(socket, fn s -> %{s | skipped: !s.skipped} end)
    {:noreply, auto_save_slot(socket)}
  end

  def handle_event("toggle_eating_out", _, socket) do
    {:noreply, update_slot(socket, fn s -> %{s | eating_out_open: !s.eating_out_open} end)}
  end

  def handle_event("save_eating_out", %{"place" => place, "amount" => amount}, socket) do
    %{plan_id: plan_id, slot_action: %{slot_key: sk}} = socket.assigns

    case Planning.eat_out(socket.assigns.current_scope, plan_id, sk, %{
           place: place,
           amount: amount
         }) do
      {:ok, _events} ->
        {:noreply, assign(socket, slot_action: nil)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't save that. Check the amount."))}
    end
  end

  def handle_event("clear_eating_out", _, socket) do
    %{plan_id: plan_id, slot_action: %{slot_key: sk}} = socket.assigns
    Planning.remove_recipe(socket.assigns.current_scope, plan_id, sk)
    {:noreply, assign(socket, slot_action: nil)}
  end

  def handle_event("toggle_pinned", _, socket) do
    %{slot_key: sk, pinned: was_pinned} = socket.assigns.slot_action
    plan_id = socket.assigns.plan_id

    if was_pinned,
      do: Planning.unpin_slot(socket.assigns.current_scope, plan_id, sk),
      else: Planning.pin_slot(socket.assigns.current_scope, plan_id, sk, true)

    {:noreply, update_slot(socket, fn s -> %{s | pinned: !was_pinned} end)}
  end

  def handle_event("save_slot", _, socket) do
    {:noreply, assign(socket, slot_action: nil)}
  end

  def handle_event("regenerate_suggestion", _, socket) do
    s = socket.assigns.slot_action
    %{plan_id: plan_id, current_scope: scope} = socket.assigns
    sk = s.slot_key

    dietary_guidance =
      Tore.Household.get_preferences(scope) |> Tore.Household.prefs_to_dietary_guidance()

    ToreWeb.Background.run(
      fn ->
        Planning.suggest_recipes_for_slot(scope, plan_id, sk,
          limit: 5,
          include_llm: true,
          dietary_guidance: dietary_guidance
        )
      end,
      fn
        {:ok, suggestions} -> {:suggestions_loaded, sk, suggestions}
        {:error, reason} -> {:suggestion_error, sk, reason}
      end
    )

    {:noreply, update_slot(socket, fn s -> %{s | loading_suggestions: true} end)}
  end

  def handle_event("remove_meal", %{"slot_key" => sk}, socket) do
    Planning.remove_recipe(socket.assigns.current_scope, socket.assigns.plan_id, sk)
    {:noreply, socket}
  end

  def handle_event("set_week_mode", %{"mode" => mode}, socket) do
    case Tore.WeekMode.set_mode(socket.assigns.current_scope, mode) do
      {:ok, _} ->
        {:noreply, assign(socket, current_week_mode: mode)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("slot_command", %{"command" => command}, socket) when command != "" do
    %{slot_key: slot_key} = socket.assigns.slot_action

    # Save pending sheet edits before the run starts, so the agent plans
    # against what the user sees and the save can't land after the run applies.
    socket = auto_save_slot(socket)
    start_command(socket, command, slot_key)

    {:noreply, assign(socket, slot_action: nil, quick_loading: true)}
  end

  def handle_event("slot_command", _params, socket), do: {:noreply, socket}

  defp maybe_toast_reverted(socket, %KitchenRun{status: :reverted, surface: :plan}),
    do: put_flash(socket, :info, gettext("Undone."))

  defp maybe_toast_reverted(socket, _run), do: socket

  # The run's own process ends it failed if it crashes, so the reply always comes.
  defp start_command(socket, command, scoped_slot) do
    scope = socket.assigns.current_scope

    ctx = %{
      command: command,
      plan_stream_id: socket.assigns.plan_id,
      week_start: socket.assigns.week_start,
      scoped_slot: scoped_slot
    }

    ToreWeb.Background.run(
      fn -> Runs.start(scope, PlannerCommand, ctx) end,
      &{:run_dispatched, &1}
    )
  end

  def handle_info({:run_dispatched, {:ok, state}}, socket) do
    {:noreply, assign(socket, current_run: state, quick_loading: false)}
  end

  def handle_info({:run_dispatched, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(
       :error,
       Tore.LLM.refusal_text(reason) ||
         gettext("Tore couldn't finish that. Try again in a moment.")
     )
     |> assign(quick_loading: false)}
  end

  def handle_info({:run_changed, %KitchenRun{} = run}, socket) do
    current = socket.assigns[:current_run]
    socket = maybe_toast_reverted(socket, run)

    if current && current.id == run.id do
      {:noreply, assign(socket, current_run: run)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:events, _events}, socket) do
    {:ok, plan_state} = Planning.load_plan(socket.assigns.current_scope, socket.assigns.plan_id)

    socket =
      assign(socket,
        plan_state: plan_state,
        plan_health: PlanHealth.compute(plan_state)
      )

    {:noreply, socket}
  end

  def handle_info({:suggestions_loaded, sk, suggestions}, socket) do
    case socket.assigns.slot_action do
      %{slot_key: ^sk} = s ->
        {:noreply,
         assign(socket, slot_action: %{s | suggestions: suggestions, loading_suggestions: false})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:suggestion_error, sk, reason}, socket) do
    case socket.assigns.slot_action do
      %{slot_key: ^sk} = s ->
        msg =
          case reason do
            refused when refused in [:ai_unavailable, :budget_exceeded] ->
              Tore.LLM.refusal_text(refused)

            :cooldown ->
              gettext("Please wait a moment before trying again")

            _ ->
              gettext("Couldn't fetch a new suggestion")
          end

        {:noreply,
         socket
         |> put_flash(:error, msg)
         |> assign(slot_action: %{s | loading_suggestions: false})}

      _ ->
        {:noreply, socket}
    end
  end

  defp update_slot(socket, fun) do
    case socket.assigns.slot_action do
      nil -> socket
      s -> assign(socket, slot_action: fun.(s))
    end
  end

  # What the sheet would write to the plan. The sheet saves on every change and on close;
  # comparing with what was last saved keeps an untouched sheet from writing the day again.
  defp slot_choice(s), do: {s.skipped, s.selected_recipe_id, s.servings, s.leftover_days}

  defp auto_save_slot(socket) do
    s = socket.assigns.slot_action

    if s == nil or s.saved == slot_choice(s) do
      socket
    else
      %{plan_id: plan_id, current_scope: scope} = socket.assigns

      cond do
        s.skipped ->
          slot = Map.get(socket.assigns.plan_state.slots, s.slot_key)
          if slot, do: Planning.skip_meal(scope, plan_id, s.slot_key)

        s.selected_recipe_id ->
          Planning.assign_with_leftovers(
            scope,
            plan_id,
            s.slot_key,
            s.selected_recipe_id,
            s.servings,
            MapSet.to_list(s.leftover_days)
          )

        true ->
          :noop
      end

      update_slot(socket, &%{&1 | saved: slot_choice(&1)})
    end
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        days: @days,
        week_end: Date.add(assigns.week_start, 6),
        week_number: Tore.Streams.week_number(assigns.week_start)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      current_user={@current_user}
    >
      <.page max_width={:md}>
        <header class="flex items-end justify-between gap-4 pt-2">
          <div class="min-w-0">
            <h1
              class="num font-bold text-[var(--text)]"
              style="font-size: var(--t-h1); line-height: 1.15;"
            >
              {gettext("Week %{week}", week: @week_number)}
            </h1>
            <p class="num mt-1 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
              {ToreWeb.Dates.range(@week_start, @week_end)}
            </p>
          </div>
          <div class="flex shrink-0 items-center">
            <button
              type="button"
              phx-click="prev_week"
              class="inline-flex size-11 items-center justify-center rounded-[var(--r-pill)] text-[color:var(--muted)] hover:bg-[var(--sunken)] hover:text-[var(--text)]"
              aria-label={gettext("Previous week")}
            >
              <.icon name="hero-chevron-left" class="size-5" />
            </button>
            <button
              type="button"
              phx-click="next_week"
              class="inline-flex size-11 items-center justify-center rounded-[var(--r-pill)] text-[color:var(--muted)] hover:bg-[var(--sunken)] hover:text-[var(--text)]"
              aria-label={gettext("Next week")}
            >
              <.icon name="hero-chevron-right" class="size-5" />
            </button>
          </div>
        </header>
        <div class="rim mt-4" aria-hidden="true"></div>

        <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 py-3">
          <p class={[
            "num text-[13px] font-semibold",
            elem(@plan_health, 0) == :ready && "text-[color:var(--accent-ink)]",
            elem(@plan_health, 0) in [:flexible, :fragile] && "text-[color:var(--warn)]",
            elem(@plan_health, 0) == :unplanned && "text-[color:var(--muted)]"
          ]}>
            {health_message(@plan_health)}
          </p>
          <.link
            navigate={~p"/prep"}
            data-role="prep-link"
            class="text-[13px] font-semibold text-[color:var(--accent)] hover:underline"
          >
            {gettext("Prep this week")}
          </.link>
        </div>

        <p :if={@quick_loading} class="pb-3 text-[13px] text-[color:var(--muted)]" role="status">
          {gettext("Changing the plan…")}
        </p>

        <div :if={@current_run} class="pb-3">
          <.live_component
            module={ToreWeb.Components.ReceiptLive}
            id="planner-receipt"
            run={@current_run}
          />
        </div>

        <div class="border-t border-[color:var(--border)]">
          <ul class="menu-lines" inert={if @slot_action, do: true}>
            <.day_row
              :for={{day, i} <- Enum.with_index(@days)}
              day={day}
              date={Date.add(@week_start, i)}
              today={@today}
              slot_key={"#{day}_dinner"}
              plan_state={@plan_state}
              recipes={@recipes}
              days={@days}
              focused={MapSet.member?(@focused_slots, "#{day}_dinner")}
            />
          </ul>
        </div>

        <%!-- Tuning, not the plan itself: kept quiet below the week --%>
        <details class="mt-5 border-t border-[color:var(--border)] pt-3">
          <summary class="cursor-pointer list-none text-[13px] font-semibold text-[color:var(--muted)] hover:text-[var(--text)]">
            {gettext("Planning for: %{mode}", mode: week_mode_label(@current_week_mode))}
          </summary>
          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={mode <- ~w(normal low_effort budget_week use_pantry more_leftovers)}
              type="button"
              phx-click="set_week_mode"
              phx-value-mode={mode}
              aria-pressed={to_string(@current_week_mode == mode)}
              class={[
                "rounded-[var(--r-pill)] border px-3 py-1.5 text-[13px] font-medium transition-colors",
                @current_week_mode == mode &&
                  "bg-[color:var(--text)] text-[color:var(--bg)] border-[color:var(--text)]",
                @current_week_mode != mode &&
                  "bg-[var(--surface)] text-[color:var(--muted)] border-[color:var(--border)] hover:text-[var(--text)]"
              ]}
            >
              {week_mode_label(mode)}
            </button>
          </div>
        </details>

        <.slot_modal
          :if={@slot_action}
          slot_action={@slot_action}
          plan_state={@plan_state}
          recipes={@recipes}
        />
      </.page>
    </Layouts.app>
    """
  end

  attr :day, :string, required: true
  attr :date, :any, required: true
  attr :today, :any, required: true
  attr :slot_key, :string, required: true
  attr :plan_state, :any, required: true
  attr :recipes, :list, required: true
  attr :days, :list, required: true
  attr :focused, :boolean, default: false

  defp day_row(assigns) do
    slot = Map.get(assigns.plan_state.slots, assigns.slot_key)
    recipe = recipe_by_id(assigns.recipes, slot[:recipe_id])
    is_today = assigns.date == assigns.today
    pinned = Map.has_key?(assigns.plan_state.pins, assigns.slot_key)
    assigns = assign(assigns, slot: slot, recipe: recipe, is_today: is_today, pinned: pinned)

    ~H"""
    <li
      id={"slot-#{@slot_key}"}
      class={[
        "transition-colors",
        @slot && @slot.skipped && !State.eating_out?(@slot) && "opacity-50",
        @focused && "ring-2 ring-[color:var(--accent)] rounded-[var(--r-md)]"
      ]}
    >
      <div
        phx-click="open_slot"
        phx-value-slot_key={@slot_key}
        class="-mx-2 flex min-h-[68px] cursor-pointer items-center gap-4 rounded-[var(--r-md)] px-2 py-3 hover:bg-[var(--sunken)]"
        role="button"
        tabindex="0"
        aria-label={gettext("Edit %{label}", label: slot_label(@slot_key))}
      >
        <div class="min-w-0 flex-1">
          <p class={[
            "text-[13px] font-semibold",
            @is_today && "text-[color:var(--accent)]",
            !@is_today && "text-[color:var(--muted)]"
          ]}>
            {ToreWeb.Dates.weekday(@date)}{if @is_today, do: gettext(", today")}
            <span :if={@pinned} data-pinned="true" title={gettext("Pinned")} class="ml-1 align-[-2px]">
              <.icon name="hero-lock-closed" class="size-3.5" />
            </span>
          </p>
          <%= cond do %>
            <% @recipe -> %>
              <p
                class="line-clamp-2 font-semibold text-[var(--text)]"
                style="font-size: 18px; line-height: 1.25; letter-spacing: -0.01em;"
              >
                {@recipe.title}
              </p>
              <div
                class="num mt-0.5 flex items-center gap-3 text-[color:var(--muted)]"
                style="font-size: var(--t-meta);"
              >
                <span :if={@slot.servings}>
                  {gettext("%{n} servings", n: @slot.servings)}
                </span>
                <span :if={@slot.leftover} class="inline-flex items-center gap-1">
                  <.icon name="hero-arrow-uturn-right" class="size-3.5" /> {gettext("Uses leftovers")}
                </span>
              </div>
            <% @slot && @slot.leftover -> %>
              <p class="text-[color:var(--muted)]" style="font-size: 18px; line-height: 1.25;">
                {gettext("Leftovers")}
              </p>
            <% State.eating_out?(@slot) -> %>
              <p class="text-[color:var(--muted)]" style="font-size: 18px; line-height: 1.25;">
                {gettext("Eating out")}
              </p>
            <% @slot && @slot.skipped -> %>
              <p class="text-[color:var(--subtle)]" style="font-size: 18px; line-height: 1.25;">
                {gettext("Skipped")}
              </p>
            <% true -> %>
              <p class="text-[color:var(--subtle)]" style="font-size: 18px; line-height: 1.25;">
                {gettext("Open")}
              </p>
          <% end %>
        </div>

        <img
          :if={@recipe && @recipe.image_path}
          src={~p"/images/recipes/#{@recipe.id}"}
          alt=""
          loading="lazy"
          class="size-[72px] shrink-0 rounded-[var(--r-md)] object-cover"
        />
        <.chip :if={leftover_target(@plan_state, @days, @date) != nil} tone={:accent}>
          {gettext("Leftovers for %{day}", day: leftover_target(@plan_state, @days, @date))}
        </.chip>
      </div>
    </li>
    """
  end

  # If this day has a meal AND the next day(s) consume leftovers from it, show
  # the chip with the consuming day name(s).
  defp leftover_target(plan_state, days, date) do
    weekday_idx = Date.day_of_week(date) - 1

    next =
      days
      |> Enum.with_index()
      |> Enum.drop(weekday_idx + 1)
      |> Enum.find(fn {d, _} ->
        slot = Map.get(plan_state.slots, "#{d}_dinner")
        slot && slot.leftover
      end)

    case next do
      {d, _} -> String.capitalize(d)
      nil -> nil
    end
  end

  attr :slot_action, :map, required: true
  attr :plan_state, :any, required: true
  attr :recipes, :list, required: true

  defp slot_modal(assigns) do
    sa = assigns.slot_action
    selected = Enum.find(assigns.recipes, &(&1.id == sa.selected_recipe_id))
    suggested_ids = MapSet.new(sa.suggestions, & &1.recipe.id)

    other_recipes =
      assigns.recipes
      |> Enum.reject(&MapSet.member?(suggested_ids, &1.id))
      |> filter_recipes(sa.search)

    assigns =
      assign(assigns,
        selected_recipe: selected,
        suggested_ids: suggested_ids,
        other_recipes: other_recipes,
        days_after: days_after(sa.slot_key)
      )

    ~H"""
    <%!-- Backdrop: JS-only dismiss so phx-click on backdrop can't swallow card clicks --%>
    <div class="fixed inset-0 z-50 flex items-end md:items-center justify-center p-4">
      <%!-- The actual dimmed backdrop, purely decorative — dismiss handled below --%>
      <div class="absolute inset-0 bg-black/40" phx-click="close_slot"></div>

      <%!-- Card wrapper sits above the backdrop; ESC closes, outside-click closes --%>
      <div
        class="relative w-full md:max-w-md"
        phx-window-keydown="close_slot"
        phx-key="Escape"
      >
        <div class={[
          "slot-panel-wrap bg-[var(--surface)] rounded-[var(--r-xl)] shadow-[var(--shadow-pop)]",
          @slot_action.flipped && "is-flipped"
        ]}>
          <%!-- FRONT PANEL --%>
          <div class="slot-panel slot-panel-front overflow-hidden rounded-[var(--r-xl)]">
            <header class="flex items-center justify-between px-6 py-4 border-b border-[color:var(--hairline)]">
              <h2 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h2);">
                {slot_label(@slot_action.slot_key)}
              </h2>
              <button
                type="button"
                phx-click="close_slot"
                class="size-9 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--muted)] hover:bg-[color:var(--hairline)]"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </header>

            <%= if @selected_recipe do %>
              <div class="aspect-[16/9] w-full bg-[color:var(--hairline)] flex items-center justify-center text-[color:var(--subtle)]">
                <img
                  :if={@selected_recipe.image_path}
                  src={~p"/images/recipes/#{@selected_recipe.id}"}
                  alt=""
                  class="h-full w-full object-cover"
                />
                <.icon :if={!@selected_recipe.image_path} name="hero-photo" class="size-10" />
              </div>
              <div class="px-6 pt-4">
                <p class="font-semibold text-[var(--text)]" style="font-size: var(--t-h2);">
                  {@selected_recipe.title}
                </p>
                <div :if={@selected_recipe.tags != []} class="flex flex-wrap gap-1.5 mt-2">
                  <.chip :for={tag <- Enum.take(@selected_recipe.tags, 3)} tone={:accent}>
                    {tag.name}
                  </.chip>
                </div>
              </div>
            <% else %>
              <div class="px-6 pt-6 pb-2">
                <p class="text-[color:var(--muted)]" style="font-size: var(--t-body);">
                  {if @slot_action.eating_out,
                    do: gettext("Eating out. Change recipe to cook instead."),
                    else: gettext("No meal chosen yet — tap Change recipe to pick one.")}
                </p>
              </div>
            <% end %>

            <div class={[
              "px-6 py-5 space-y-4",
              @slot_action.skipped && "opacity-40 pointer-events-none"
            ]}>
              <div class="flex items-center justify-between">
                <span
                  class="text-[color:var(--muted)]"
                  style="font-size: var(--t-meta); font-weight: 500;"
                >
                  {gettext("Portions")}
                </span>
                <div class="inline-flex items-center gap-3">
                  <button
                    type="button"
                    phx-click="dec_servings"
                    class="size-9 inline-flex items-center justify-center rounded-[var(--r-md)] border border-[color:var(--border)] hover:border-[color:var(--subtle)]"
                  >
                    <.icon name="hero-minus" class="size-4" />
                  </button>
                  <span
                    class="w-6 text-center font-semibold tabular-nums"
                    style="font-size: var(--t-h2);"
                  >
                    {@slot_action.servings}
                  </span>
                  <button
                    type="button"
                    phx-click="inc_servings"
                    class="size-9 inline-flex items-center justify-center rounded-[var(--r-md)] border border-[color:var(--border)] hover:border-[color:var(--subtle)]"
                  >
                    <.icon name="hero-plus" class="size-4" />
                  </button>
                </div>
              </div>

              <div
                :if={@days_after != [] and @slot_action.selected_recipe_id}
                class="flex items-start gap-3"
              >
                <span
                  class="text-[color:var(--muted)] mt-1.5"
                  style="font-size: var(--t-meta); font-weight: 500;"
                >
                  {gettext("Leftovers for")}
                </span>
                <div class="flex flex-wrap gap-1.5">
                  <button
                    :for={d <- @days_after}
                    type="button"
                    phx-click="toggle_leftover_day"
                    phx-value-day={"#{d}_dinner"}
                    class={[
                      "h-7 px-2.5 rounded-[var(--r-pill)] capitalize transition-colors",
                      MapSet.member?(@slot_action.leftover_days, "#{d}_dinner") &&
                        "bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)] font-medium",
                      !MapSet.member?(@slot_action.leftover_days, "#{d}_dinner") &&
                        "bg-[color:var(--hairline)] text-[color:var(--muted)] hover:text-[var(--text)]"
                    ]}
                    style="font-size: var(--t-meta);"
                  >
                    {String.capitalize(d)}
                  </button>
                </div>
              </div>
            </div>

            <div class="px-6 pb-5 border-t border-[color:var(--hairline)] pt-4 flex flex-wrap items-center gap-x-2 gap-y-2 [&>button]:whitespace-nowrap">
              <button
                type="button"
                phx-click="flip_slot"
                class="inline-flex items-center gap-1.5 text-[color:var(--accent)] hover:underline"
                style="font-size: var(--t-meta); font-weight: 500;"
              >
                <.icon name="hero-arrow-path" class="size-4" /> {gettext("Change recipe")}
              </button>

              <button
                type="button"
                phx-click="toggle_skipped"
                class={[
                  "inline-flex items-center gap-2 rounded-[var(--r-pill)] px-3 h-8 transition-colors",
                  @slot_action.skipped &&
                    "bg-[color:var(--warn-soft)] text-[color:var(--warn)] font-medium",
                  !@slot_action.skipped &&
                    "text-[color:var(--muted)] hover:text-[var(--text)] hover:bg-[color:var(--hairline)]"
                ]}
                style="font-size: var(--t-meta);"
              >
                <.icon
                  name={if @slot_action.skipped, do: "hero-x-circle", else: "hero-x-circle"}
                  class="size-4"
                />
                {if @slot_action.skipped, do: gettext("Skipped"), else: gettext("Skip dinner")}
              </button>

              <button
                type="button"
                phx-click="toggle_eating_out"
                class={[
                  "inline-flex items-center gap-2 rounded-[var(--r-pill)] px-3 h-8 transition-colors",
                  @slot_action.eating_out_open &&
                    "bg-[color:var(--accent-soft)] text-[color:var(--accent)] font-medium",
                  !@slot_action.eating_out_open &&
                    "text-[color:var(--muted)] hover:text-[var(--text)] hover:bg-[color:var(--hairline)]"
                ]}
                style="font-size: var(--t-meta);"
              >
                <.icon name="hero-building-storefront" class="size-4" />
                {gettext("Eating out")}
              </button>

              <button
                type="button"
                phx-click="toggle_pinned"
                class={[
                  "inline-flex items-center gap-2 rounded-[var(--r-pill)] px-3 h-8 transition-colors",
                  @slot_action.pinned &&
                    "bg-[color:var(--accent-soft)] text-[color:var(--accent)] font-medium",
                  !@slot_action.pinned &&
                    "text-[color:var(--muted)] hover:text-[var(--text)] hover:bg-[color:var(--hairline)]"
                ]}
                style="font-size: var(--t-meta);"
              >
                <.icon
                  name={if @slot_action.pinned, do: "hero-lock-closed", else: "hero-lock-open"}
                  class="size-4"
                />
                {if @slot_action.pinned, do: gettext("Pinned"), else: gettext("Pin this day")}
              </button>
            </div>

            <form
              :if={@slot_action.eating_out_open}
              id="eating-out-form"
              phx-submit="save_eating_out"
              class="px-6 pb-5 space-y-3"
            >
              <.field
                name="place"
                label={gettext("Place (optional)")}
                value={@slot_action.dining && @slot_action.dining.place}
              />
              <.field
                name="amount"
                type="number"
                step="0.01"
                min="0"
                label={gettext("Total, kr (optional)")}
                value={@slot_action.dining && @slot_action.dining.amount}
              />
              <div class="flex gap-3">
                <.button type="submit" variant={:primary} size={:md} full>
                  {gettext("Save")}
                </.button>
                <.button
                  :if={@slot_action.eating_out}
                  type="button"
                  phx-click="clear_eating_out"
                  variant={:ghost}
                  size={:md}
                >
                  {gettext("Not eating out")}
                </.button>
              </div>
            </form>

            <form phx-submit="slot_command" class="px-6 pb-6">
              <input
                type="text"
                name="command"
                autocomplete="off"
                placeholder={gettext("Anything about this day…")}
                class="w-full rounded-[var(--r-md)] border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
              />
            </form>
          </div>

          <%!-- BACK PANEL (recipe browser) --%>
          <div
            class="slot-panel slot-panel-back overflow-hidden rounded-[var(--r-xl)] flex flex-col"
            style="max-height: 80vh;"
          >
            <header class="flex items-center gap-3 px-6 py-4 border-b border-[color:var(--hairline)] shrink-0">
              <button
                type="button"
                phx-click="flip_slot"
                class="size-9 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--muted)] hover:bg-[color:var(--hairline)]"
              >
                <.icon name="hero-chevron-left" class="size-5" />
              </button>
              <h2 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h2);">
                {gettext("Choose a recipe")}
              </h2>
            </header>

            <div class="flex-1 overflow-y-auto px-6 pt-4 pb-6 space-y-4">
              <form phx-change="search_slot_recipes">
                <div class="relative">
                  <.icon
                    name="hero-magnifying-glass"
                    class="size-5 absolute left-3.5 top-1/2 -translate-y-1/2 text-[color:var(--subtle)]"
                  />
                  <input
                    type="text"
                    name="q"
                    value={@slot_action.search}
                    placeholder={gettext("Search recipes…")}
                    class="w-full h-11 pl-10 pr-3 bg-[var(--surface)] rounded-[var(--r-lg)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
                    style="font-size: var(--t-body);"
                  />
                </div>
              </form>

              <%= if @slot_action.search == "" do %>
                <section>
                  <div class="flex items-center justify-between mb-2">
                    <h3 class="section-label">
                      {gettext("Suggested")}
                    </h3>
                    <button
                      type="button"
                      phx-click="regenerate_suggestion"
                      disabled={@slot_action.loading_suggestions}
                      class="inline-flex items-center gap-1 text-[color:var(--accent)] hover:underline disabled:opacity-40"
                      style="font-size: var(--t-meta);"
                    >
                      <.icon name="hero-sparkles" class="size-3.5" /> {gettext("Surprise me")}
                    </button>
                  </div>

                  <%= if @slot_action.loading_suggestions and @slot_action.suggestions == [] do %>
                    <p class="text-[color:var(--muted)] py-2" style="font-size: var(--t-meta);">
                      {gettext("Finding suggestions…")}
                    </p>
                  <% else %>
                    <ul class="space-y-2">
                      <.recipe_pick_row
                        :for={sug <- @slot_action.suggestions}
                        recipe={sug.recipe}
                        reasons={sug.reasons}
                        selected={@slot_action.selected_recipe_id == sug.recipe.id}
                      />
                    </ul>
                  <% end %>
                </section>
              <% end %>

              <section>
                <h3 class="section-label mb-2">
                  {if @slot_action.search == "", do: gettext("All recipes"), else: gettext("Results")}
                </h3>
                <ul class="space-y-2">
                  <.recipe_pick_row
                    :for={r <- @other_recipes}
                    recipe={r}
                    reasons={[]}
                    selected={@slot_action.selected_recipe_id == r.id}
                  />
                </ul>
                <p
                  :if={@other_recipes == [] and @slot_action.search != ""}
                  class="text-[color:var(--muted)] py-2"
                  style="font-size: var(--t-meta);"
                >
                  {gettext("No recipes match.")}
                </p>
              </section>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :recipe, :any, required: true
  attr :reasons, :list, default: []
  attr :selected, :boolean, default: false

  defp recipe_pick_row(assigns) do
    total = (assigns.recipe.prep_time_minutes || 0) + (assigns.recipe.cook_time_minutes || 0)
    assigns = assign(assigns, total_min: total)

    ~H"""
    <li>
      <button
        type="button"
        phx-click="pick_recipe"
        phx-value-id={@recipe.id}
        class={[
          "w-full flex items-start gap-3 p-3 rounded-[var(--r-lg)] border text-left transition-colors",
          @selected && "border-[color:var(--accent)] bg-[color:var(--accent-soft)]/40",
          !@selected && "border-[color:var(--border)] hover:border-[color:var(--subtle)]"
        ]}
      >
        <div class="size-12 shrink-0 rounded-[var(--r-md)] overflow-hidden bg-[color:var(--hairline)] flex items-center justify-center text-[color:var(--subtle)]">
          <img
            :if={@recipe.image_path}
            src={~p"/images/recipes/#{@recipe.id}"}
            alt=""
            class="h-full w-full object-cover"
          />
          <.icon :if={!@recipe.image_path} name="hero-photo" class="size-5" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="font-semibold text-[var(--text)] truncate" style="font-size: var(--t-body);">
            {@recipe.title}
          </p>
          <p class="mt-0.5 text-[color:var(--muted)] truncate" style="font-size: var(--t-meta);">
            <%= if @reasons != [] do %>
              {Enum.join(@reasons, " · ")}
            <% else %>
              {if @total_min > 0, do: gettext("%{n} min", n: @total_min), else: ""}{if @recipe.base_servings,
                do: " · #{gettext("%{n} portions", n: @recipe.base_servings)}",
                else: ""}
            <% end %>
          </p>
        </div>
      </button>
    </li>
    """
  end

  defp load_week(socket, week_start) do
    scope = socket.assigns.current_scope
    plan_id = plan_id(scope, week_start)
    {:ok, plan_state} = Planning.load_plan(scope, plan_id)

    assign(socket,
      week_start: week_start,
      plan_id: plan_id,
      plan_state: plan_state,
      plan_health: PlanHealth.compute(plan_state)
    )
  end

  defp recipe_by_id(_recipes, nil), do: nil
  defp recipe_by_id(recipes, id), do: Enum.find(recipes, &(&1.id == id))

  defp week_mode_label("normal"), do: gettext("Normal")
  defp week_mode_label("low_effort"), do: gettext("Low effort")
  defp week_mode_label("budget_week"), do: gettext("Budget")
  defp week_mode_label("use_pantry"), do: gettext("Use pantry")
  defp week_mode_label("more_leftovers"), do: gettext("More leftovers")

  defp day_name(abbr) do
    case abbr do
      "mon" -> gettext("Monday")
      "tue" -> gettext("Tuesday")
      "wed" -> gettext("Wednesday")
      "thu" -> gettext("Thursday")
      "fri" -> gettext("Friday")
      "sat" -> gettext("Saturday")
      "sun" -> gettext("Sunday")
      other -> String.capitalize(other)
    end
  end

  defp meal_name(meal) do
    case meal do
      "lunch" -> gettext("Lunch")
      "dinner" -> gettext("Dinner")
      other -> String.capitalize(other)
    end
  end

  defp slot_label(slot_key) do
    [day, meal] = String.split(slot_key, "_", parts: 2)
    "#{day_name(day)} · #{meal_name(meal)}"
  end

  defp days_after(slot_key) do
    [day, _meal] = String.split(slot_key, "_", parts: 2)
    days = ~w[mon tue wed thu fri sat sun]
    idx = Enum.find_index(days, &(&1 == day))
    if idx, do: Enum.drop(days, idx + 1), else: []
  end

  defp filter_recipes(recipes, ""), do: recipes

  defp filter_recipes(recipes, q) do
    q = String.downcase(q)
    Enum.filter(recipes, &String.contains?(String.downcase(&1.title), q))
  end

  defp plan_id(scope, week_start), do: Tore.Streams.plan(scope, week_start)

  defp health_message({:unplanned, _}), do: gettext("No plan for this week yet")
  defp health_message({:ready, _}), do: gettext("The week is planned")

  defp health_message({:flexible, n}),
    do: ngettext("%{count} dinner unplanned", "%{count} dinners unplanned", n, count: n)

  defp health_message({:fragile, n}),
    do: ngettext("%{count} dinner skipped", "%{count} dinners skipped", n, count: n)
end
