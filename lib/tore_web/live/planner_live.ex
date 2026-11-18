defmodule ToreWeb.PlannerLive do
  use ToreWeb, :live_view

  on_mount {ToreWeb.Live.Auth, :hears_runs}

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds.PlannerCommand

  alias Tore.{Recipes, Planning}
  alias Tore.Planning.State
  alias Phoenix.PubSub

  @days ~w[mon tue wed thu fri sat sun]

  # The household's pi session the Plan screen talks in: the same conversation as its chat.
  @pi_session "chat"

  def mount(_params, _session, socket) do
    today = Tore.Clock.today()
    week_start = Tore.Streams.monday(today)
    scope = socket.assigns.current_scope
    plan_id = plan_id(scope, week_start)

    if connected?(socket) do
      # Run changes come through ToreWeb.Live.Auth, which subscribes for every view.
      PubSub.subscribe(Tore.PubSub, Tore.Planning.topic(scope))
      Tore.Pi.subscribe(scope, @pi_session)
    end

    {:ok, plan_state} = Planning.load_plan(scope, plan_id)
    recipes = Recipes.list(scope, sort: :alphabetical)
    # Only a run still working is picked up on opening; one that finished, or a question left
    # waiting from another day, isn't news here. A result still shows if it lands while open.
    current_run =
      case Runs.latest_on_surface(scope, :plan) do
        %{status: :running} = run -> run
        _other -> nil
      end

    {:ok,
     socket
     |> assign(
       today: today,
       week_start: week_start,
       plan_id: plan_id,
       recipes: recipes,
       slot_action: nil,
       current_week_mode: Tore.WeekMode.get_current_mode(scope),
       current_run: current_run,
       quick_loading: false,
       quick_label: nil,
       # What pi says while it plans from this screen; nil when it wasn't asked here.
       pi_reply: nil,
       focused_slots: MapSet.new(),
       view: :week,
       month: nil,
       month_weeks: nil
     )
     |> with_plan(plan_state)}
  end

  # The plan, how ready it is, and what it's estimated to cost against the week's budget.
  defp with_plan(socket, plan_state) do
    %{current_scope: scope, week_start: week_start} = socket.assigns

    assign(socket,
      plan_state: plan_state,
      budget: Tore.Budget.status(scope, plan_state, week_start),
      verdict: Tore.Budget.verdict(scope, week_start, socket.assigns.today)
    )
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

  # The month opens on the month the week shown is in (its Thursday's, as week numbers count).
  def handle_event("set_plan_view", %{"view" => "month"}, socket) do
    month = socket.assigns.week_start |> Date.add(3) |> Date.beginning_of_month()
    {:noreply, socket |> assign(view: :month) |> load_month(month)}
  end

  def handle_event("set_plan_view", %{"view" => "week"}, socket),
    do: {:noreply, assign(socket, view: :week)}

  def handle_event("prev_month", _params, socket),
    do: {:noreply, load_month(socket, Date.shift(socket.assigns.month, month: -1))}

  def handle_event("next_month", _params, socket),
    do: {:noreply, load_month(socket, Date.shift(socket.assigns.month, month: 1))}

  # A day in the month opens its week.
  def handle_event("open_week", %{"date" => date}, socket) do
    week_start = date |> Date.from_iso8601!() |> Tore.Streams.monday()
    {:noreply, socket |> assign(view: :week) |> load_week(week_start)}
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
      prices: %{},
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
          limit: 3,
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
          limit: 3,
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
    {:noreply, assign(socket, slot_action: nil)}
  end

  # From a day's dinner sheet to its lunch, saving the dinner first.
  def handle_event("open_lunch", _params, socket) do
    socket = auto_save_slot(socket)
    [day, _meal] = String.split(socket.assigns.slot_action.slot_key, "_", parts: 2)
    handle_event("open_slot", %{"slot_key" => "#{day}_lunch"}, socket)
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

  # pi fills the days still open; they change on screen as it sets each one, and what it says
  # streams in below the buttons.
  def handle_event("plan_week", _params, socket) do
    %{current_scope: scope, week_start: week_start, today: today} = socket.assigns
    from = Enum.max([week_start, today], Date)

    message = """
    From the Plan screen: plan dinners for the open days from #{Date.to_iso8601(from)} to \
    #{week_start |> Date.add(6) |> Date.to_iso8601()}. Keep every day that already has a dinner, \
    is skipped or is eating out. Then say in a sentence or two what you planned.\
    """

    case Tore.Pi.ask(scope, @pi_session, message) do
      :ok ->
        {:noreply,
         assign(socket,
           quick_loading: true,
           quick_label: gettext("Planning the open days…"),
           pi_reply: ""
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("dismiss_pi_reply", _params, socket),
    do: {:noreply, assign(socket, pi_reply: nil)}

  defp refusal(reason),
    do:
      Tore.LLM.refusal_text(reason) ||
        gettext("Tore couldn't finish that. Try again in a moment.")

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
    {:noreply, assign(socket, current_run: state, quick_loading: false, quick_label: nil)}
  end

  def handle_info({:run_dispatched, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, refusal(reason))
     |> assign(quick_loading: false, quick_label: nil)}
  end

  # pi's events, heard only while it is answering something asked from this screen.
  def handle_info({:pi, _session, _event}, %{assigns: %{pi_reply: nil}} = socket),
    do: {:noreply, socket}

  def handle_info({:pi, _session, event}, socket), do: {:noreply, pi_event(socket, event)}

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
    socket = with_plan(socket, plan_state)

    {:noreply,
     if(socket.assigns.view == :month, do: load_month(socket, socket.assigns.month), else: socket)}
  end

  def handle_info({:suggestions_loaded, sk, suggestions}, socket) do
    case socket.assigns.slot_action do
      %{slot_key: ^sk} = s ->
        prices = suggestion_prices(socket, s, suggestions)

        {:noreply,
         assign(socket,
           slot_action: %{
             s
             | suggestions: suggestions,
               prices: prices,
               loading_suggestions: false
           }
         )}

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

  defp pi_event(socket, %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}
       }),
       do: update(socket, :pi_reply, &(&1 <> delta))

  # Each new message replaces the last: what's shown is what pi says now, and at the end its
  # summary.
  defp pi_event(socket, %{"type" => "message_start", "message" => %{"role" => "assistant"}}),
    do: assign(socket, pi_reply: "")

  defp pi_event(socket, %{"type" => "message_end", "message" => %{"role" => "assistant"} = m}),
    do: assign(socket, pi_reply: Tore.Pi.assistant_text(m) || socket.assigns.pi_reply)

  defp pi_event(socket, %{"type" => "agent_settled"}),
    do: assign(socket, quick_loading: false, quick_label: nil)

  defp pi_event(socket, %{"type" => "exited"}) do
    socket
    |> put_flash(:error, refusal(:exited))
    |> assign(quick_loading: false, quick_label: nil, pi_reply: nil)
  end

  defp pi_event(socket, _event), do: socket

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
        <.top_bar>
          <:actions>
            <.page_menu id="plan-menu">
              <.menu_item
                menu="plan-menu"
                icon="ph-squares-four"
                navigate={~p"/prep"}
                data-role="prep-link"
              >
                {gettext("Prep this week")}
              </.menu_item>
            </.page_menu>
          </:actions>
        </.top_bar>

        <%!-- The page: its icon, the week, and one line with the dates and the money --%>
        <header class="pt-1">
          <.page_icon icon="ph-calendar-blank-duotone" tint="blue" />
          <div class="mt-3 flex items-center justify-between gap-3">
            <h1 :if={@view == :week} class="t-display num">
              {gettext("Week %{week}", week: @week_number)}
            </h1>
            <h1 :if={@view == :month} class="t-display num">
              {ToreWeb.Dates.month_year(@month)}
            </h1>
            <div class="-mr-2 flex shrink-0 items-center">
              <button
                type="button"
                phx-click={if @view == :month, do: "prev_month", else: "prev_week"}
                class="icon-btn press"
                aria-label={
                  if @view == :month, do: gettext("Previous month"), else: gettext("Previous week")
                }
              >
                <.icon name="ph-caret-left" class="size-5" />
              </button>
              <button
                type="button"
                phx-click={if @view == :month, do: "next_month", else: "next_week"}
                class="icon-btn press"
                aria-label={if @view == :month, do: gettext("Next month"), else: gettext("Next week")}
              >
                <.icon name="ph-caret-right" class="size-5" />
              </button>
            </div>
          </div>
          <p
            :if={@view == :month}
            class="num mt-1 text-[color:var(--muted)]"
            style="font-size: 15px;"
          >
            {ngettext(
              "%{count} dinner planned",
              "%{count} dinners planned",
              planned_in(@month_weeks)
            )}
          </p>
          <p :if={@view == :week} class="num mt-1 text-[color:var(--muted)]" style="font-size: 15px;">
            {ToreWeb.Dates.range(@week_start, @week_end)}<span
              :if={@verdict}
              id={"week-verdict-#{@week_start}-#{@verdict.spent}-#{@verdict.budget}"}
              data-role="week-verdict"
              class={[
                "settle",
                @verdict.budget && Decimal.gt?(@verdict.spent, @verdict.budget) &&
                  "font-semibold text-[color:var(--warn)]"
              ]}
            > · {verdict_line(@verdict)}</span>
            <.link
              :if={!@verdict and (@budget.estimate.total > 0 or @budget.budget)}
              navigate={~p"/budget"}
              class="hover:underline"
            >
              <span
                id={"week-estimate-#{@week_start}-#{@budget.expected}-#{@budget.budget}"}
                data-role="week-estimate"
                class={["settle", @budget.over && "font-semibold text-[color:var(--warn)]"]}
              >
                · {estimate_line(@budget)}
              </span>
            </.link>
          </p>
        </header>

        <%!-- The two views, then planning what's still open --%>
        <div class="mt-4 flex items-center gap-1 border-b border-[color:var(--hairline)] pb-1.5">
          <div class="flex gap-1" role="tablist">
            <button
              :for={
                {view, icon, label} <- [
                  {:week, "ph-list-bullets", gettext("Week")},
                  {:month, "ph-calendar-blank", gettext("Month")}
                ]
              }
              type="button"
              phx-click="set_plan_view"
              phx-value-view={view}
              role="tab"
              aria-selected={to_string(@view == view)}
              data-plan-view={view}
              class={[
                "view-tab press inline-flex h-8 items-center gap-1.5 rounded-[var(--r-sm)] px-2",
                @view == view && "is-open",
                @view != view && "text-[color:var(--muted)]"
              ]}
              style="font-size: 14px; font-weight: 600;"
            >
              <.icon name={icon} class="size-4" />
              {label}
            </button>
          </div>
          <span class="flex-1"></span>
          <button
            :if={@view == :week and open_days(@plan_state, @week_start, @today) > 0}
            type="button"
            phx-click="plan_week"
            disabled={@quick_loading}
            data-role="plan-week"
            class="pill pill-lamp press h-8 px-3"
          >
            {ngettext(
              "Plan %{count} day",
              "Plan %{count} days",
              open_days(@plan_state, @week_start, @today)
            )}
          </button>
        </div>

        <p
          :if={@quick_loading}
          class="mt-4 flex items-center gap-2 text-[14px] text-[color:var(--muted)]"
          role="status"
        >
          <.icon name="ph-arrows-clockwise" class="size-4 motion-safe:animate-spin" />
          {@quick_label || gettext("Changing the plan…")}
        </p>

        <div
          :if={@pi_reply not in [nil, ""]}
          data-role="pi-reply"
          class="mt-4 flex items-start gap-3 rounded-2xl bg-[var(--sunken)] px-4 py-3"
          aria-live="polite"
        >
          <p class="min-w-0 flex-1 whitespace-pre-line text-[15px] leading-snug">{@pi_reply}</p>
          <button
            :if={not @quick_loading}
            type="button"
            phx-click="dismiss_pi_reply"
            class="press -mr-1 inline-flex size-8 shrink-0 items-center justify-center rounded-full text-[color:var(--muted)] hover:bg-[var(--border)] hover:text-[var(--text)]"
            aria-label={gettext("Close")}
          >
            <.icon name="ph-x" class="size-4" />
          </button>
        </div>

        <div :if={@current_run} class="mt-4">
          <.live_component
            module={ToreWeb.Components.ReceiptLive}
            id="planner-receipt"
            run={@current_run}
          />
        </div>

        <.month_grid
          :if={@view == :month}
          weeks={@month_weeks}
          recipes={@recipes}
          today={@today}
        />

        <div :if={@view == :week} class="mt-1">
          <ul inert={if @slot_action, do: true}>
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
        <details class="mt-8">
          <summary class="cursor-pointer list-none text-[14px] font-semibold text-[color:var(--muted)] hover:text-[var(--text)]">
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
                "press h-9 rounded-full px-3.5 text-[14px] font-semibold",
                @current_week_mode == mode && "bg-[color:var(--text)] text-[color:var(--bg)]",
                @current_week_mode != mode &&
                  "bg-[var(--sunken)] text-[color:var(--muted)] hover:text-[var(--text)]"
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
    lunch_key = "#{assigns.day}_lunch"
    lunch = Map.get(assigns.plan_state.slots, lunch_key)

    assigns =
      assign(assigns,
        slot: slot,
        recipe: recipe,
        is_today: is_today,
        cooked: cooked_on?(recipe, assigns.date),
        pinned: pinned,
        lunch_key: lunch_key,
        lunch: recipe_by_id(assigns.recipes, lunch[:recipe_id]),
        # Lunch is offered on weekends, holidays and days off, never filled in by itself.
        offer_lunch:
          State.lunch_day?(assigns.plan_state, assigns.date) and
            Date.compare(assigns.date, assigns.today) != :lt,
        day_off: MapSet.member?(assigns.plan_state.days_off, assigns.date)
      )

    ~H"""
    <li
      id={"slot-#{@slot_key}"}
      class={[
        "border-b border-[color:var(--hairline)]",
        @focused && "rounded-[var(--r-md)] ring-2 ring-[color:var(--accent)]"
      ]}
    >
      <div
        :if={@lunch || @offer_lunch}
        id={"lunch-#{@lunch_key}-#{(@lunch && @lunch.id) || "open"}"}
        data-role="lunch"
        phx-click="open_slot"
        phx-value-slot_key={@lunch_key}
        class="row-hover press-soft -mx-2 grid min-h-8 cursor-pointer grid-cols-[3rem_1fr] items-center gap-2 rounded-[var(--r-sm)] px-2 pt-1.5"
        role="button"
        tabindex="0"
        aria-label={gettext("Edit %{label}", label: slot_label(@lunch_key))}
      >
        <span></span>
        <span :if={@lunch} class="flex min-w-0 items-center gap-2" style="font-size: 13.5px;">
          <span class="w-11 shrink-0 text-[color:var(--muted)]" style="font-size: 12px;">
            {gettext("Lunch")}
          </span>
          <span class="truncate text-[color:var(--text)]">{@lunch.title}</span>
        </span>
        <span
          :if={!@lunch}
          class="flex items-center gap-1.5 text-[color:var(--subtle)]"
          style="font-size: 13px;"
        >
          <.icon name="ph-plus" class="size-3.5" /> {gettext("Lunch")}
        </span>
      </div>
      <div
        id={"day-#{@slot_key}-#{(@recipe && @recipe.id) || "open"}"}
        phx-click="open_slot"
        phx-value-slot_key={@slot_key}
        class={[
          "reveal row-hover press-soft -mx-2 grid min-h-[60px] cursor-pointer grid-cols-[3rem_1fr_auto] items-center gap-2 rounded-[var(--r-md)] px-2 py-2",
          Date.compare(@date, @today) == :lt && "opacity-70"
        ]}
        style={"--i: #{Date.day_of_week(@date) - 1}"}
        role="button"
        tabindex="0"
        aria-label={gettext("Edit %{label}", label: slot_label(@slot_key))}
      >
        <%!-- The date, like a calendar's margin; today's number in red --%>
        <span class="leading-tight">
          <span class="block text-[12.5px] text-[color:var(--muted)]">
            {ToreWeb.Dates.weekday(@date) |> String.slice(0, 3) |> String.downcase()}
          </span>
          <span class={[
            "num block text-[18px] font-semibold",
            @is_today && "text-[color:var(--tag-red-ink)]",
            !@is_today && "text-[color:var(--text)]"
          ]}>
            {@date.day}
          </span>
          <span
            :if={@day_off}
            data-role="day-off"
            class="block text-[11px] text-[color:var(--muted)]"
          >
            {gettext("Day off")}
          </span>
        </span>

        <%= if @recipe do %>
          <span class="flex min-w-0 items-center gap-3">
            <span class="relative size-11 shrink-0 overflow-hidden rounded-[var(--r-md)]">
              <img
                :if={@recipe.image_path}
                src={~p"/images/recipes/#{@recipe.id}"}
                alt=""
                loading="lazy"
                class="size-full object-cover"
              />
              <.blank_cover :if={!@recipe.image_path} dish={@recipe} icon_class="size-6" />
            </span>
            <span class="min-w-0">
              <span
                class="block truncate font-semibold text-[color:var(--text)]"
                style="font-size: 15.5px;"
              >
                {@recipe.title}
              </span>
              <span class="mt-1 flex flex-wrap items-center gap-1.5">
                <span :if={@cooked} class="tag tag-green">
                  <span class="tag-dot"></span>{pgettext("dinner", "Cooked")}
                </span>
                <span :if={@is_today and !@cooked} class="tag tag-red">
                  <span class="tag-dot"></span>{gettext("Tonight")}
                </span>
                <span :if={@slot.leftover} class="tag tag-purple">
                  <.icon name="ph-arrow-u-up-right" /> {gettext("Uses leftovers")}
                </span>
                <span :if={leftover_target(@plan_state, @days, @date) != nil} class="tag tag-purple">
                  <.icon name="ph-arrow-u-up-left" />
                  {gettext("Leftovers for %{day}", day: leftover_target(@plan_state, @days, @date))}
                </span>
              </span>
            </span>
          </span>
        <% else %>
          <span class="flex items-center gap-2 text-[color:var(--muted)]" style="font-size: 15px;">
            <%= cond do %>
              <% @slot && @slot.leftover -> %>
                <span class="tag tag-purple">{gettext("Leftovers")}</span>
              <% State.eating_out?(@slot) -> %>
                <span class="tag tag-grey">{gettext("Eating out")}</span>
              <% @slot && @slot.skipped -> %>
                <span class="tag tag-grey">{gettext("Skipped")}</span>
              <% Date.compare(@date, @today) == :lt -> %>
                <span class="text-[color:var(--subtle)]">—</span>
              <% true -> %>
                <span
                  class="flex items-center gap-1.5 text-[color:var(--subtle)]"
                  data-role="new-dinner"
                >
                  <.icon name="ph-plus" class="size-4" /> {gettext("New dinner")}
                </span>
            <% end %>
          </span>
        <% end %>

        <span
          :if={@pinned}
          data-pinned="true"
          title={gettext("Pinned")}
          class="shrink-0 text-[color:var(--muted)]"
        >
          <.icon name="ph-lock" class="size-4" />
        </span>
        <span :if={!@pinned}></span>
      </div>
    </li>
    """
  end

  # Cooked that day: Done in cook mode records when a recipe was last made.
  defp cooked_on?(%{last_used_at: %DateTime{} = at}, date), do: Tore.Clock.date_of(at) == date
  defp cooked_on?(_recipe, _date), do: false

  defp planned_in(weeks) do
    weeks |> List.flatten() |> Enum.count(&(&1 && &1.slot && &1.slot.recipe_id))
  end

  attr :weeks, :list, required: true
  attr :recipes, :list, required: true
  attr :today, :any, required: true

  # The month as a calendar: each day's dinner as a small picture; a day opens its week.
  defp month_grid(assigns) do
    monday =
      assigns.weeks |> List.flatten() |> Enum.find(& &1) |> then(&Tore.Streams.monday(&1.date))

    assigns = assign(assigns, :weekdays, Enum.map(0..6, &Date.add(monday, &1)))

    ~H"""
    <div id="plan-month" class="mt-3">
      <div class="grid grid-cols-7 gap-1.5 pb-1 text-center text-[12px] text-[color:var(--muted)]">
        <span :for={date <- @weekdays}>{day_letters(date)}</span>
      </div>
      <div :for={week <- @weeks} class="mt-1.5 grid grid-cols-7 gap-1.5">
        <%= for day <- week do %>
          <span :if={!day} aria-hidden="true"></span>
          <.month_day :if={day} day={day} recipes={@recipes} today={@today} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :day, :map, required: true
  attr :recipes, :list, required: true
  attr :today, :any, required: true

  defp month_day(assigns) do
    slot = assigns.day.slot
    recipe = slot && recipe_by_id(assigns.recipes, slot.recipe_id)
    assigns = assign(assigns, slot: slot, recipe: recipe)

    ~H"""
    <button
      type="button"
      phx-click="open_week"
      phx-value-date={@day.date}
      data-date={@day.date}
      aria-label={
        Enum.join(
          [ToreWeb.Dates.long(@day.date), @recipe && @recipe.title] |> Enum.reject(&is_nil/1),
          ", "
        )
      }
      class={[
        "press-soft flex flex-col items-stretch gap-1 rounded-[var(--r-md)] text-left",
        Date.compare(@day.date, @today) == :lt && "opacity-70"
      ]}
    >
      <span class={[
        "num block pl-0.5 text-[13px] font-semibold",
        @day.date == @today && "text-[color:var(--tag-red-ink)]",
        @day.date != @today && "text-[color:var(--text)]"
      ]}>
        {@day.date.day}
      </span>
      <span class="relative block aspect-square w-full overflow-hidden rounded-[var(--r-sm)] bg-[var(--sunken)]">
        <img
          :if={@recipe && @recipe.image_path}
          src={~p"/images/recipes/#{@recipe.id}"}
          alt=""
          loading="lazy"
          class="absolute inset-0 size-full object-cover"
        />
        <.blank_cover
          :if={@recipe && !@recipe.image_path}
          dish={@recipe}
          icon_class="size-[55%]"
        />
        <span class="sr-only">{@recipe && @recipe.title}</span>
      </span>
    </button>
    """
  end

  # "mån", the way the week's rows start.
  defp day_letters(date),
    do: date |> ToreWeb.Dates.weekday() |> String.slice(0, 3) |> String.downcase()

  # Days from today on with nothing planned: no dinner, not skipped, not eating out.
  defp open_days(plan_state, week_start, today) do
    Enum.count(0..6, fn i ->
      date = Date.add(week_start, i)
      slot = plan_state.slots[Tore.Streams.slot_key(date)]

      Date.compare(date, today) != :lt and
        (slot == nil or (slot.recipe_id == nil and !slot.skipped))
    end)
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
      |> Enum.filter(&(&1.recipe_type == :meal))
      |> Enum.reject(&MapSet.member?(suggested_ids, &1.id))
      |> filter_recipes(sa.search)

    assigns =
      assign(assigns,
        selected_recipe: selected,
        suggested_ids: suggested_ids,
        other_recipes: other_recipes,
        days_after: days_after(sa.slot_key),
        lunch?: String.ends_with?(sa.slot_key, "_lunch"),
        lunch_key: String.replace(sa.slot_key, ~r/_dinner$/, "_lunch")
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
                <.icon name="ph-x" class="size-5" />
              </button>
            </header>

            <%= if @selected_recipe do %>
              <div class="relative aspect-[16/9] w-full">
                <img
                  :if={@selected_recipe.image_path}
                  src={~p"/images/recipes/#{@selected_recipe.id}"}
                  alt=""
                  class="h-full w-full object-cover"
                />
                <.blank_cover :if={!@selected_recipe.image_path} dish={@selected_recipe} />
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
                    <.icon name="ph-minus" class="size-4" />
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
                    <.icon name="ph-plus" class="size-4" />
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
                <.icon name="ph-arrows-clockwise" class="size-4" /> {gettext("Change recipe")}
              </button>

              <button
                :if={@lunch? and Map.has_key?(@plan_state.slots, @slot_action.slot_key)}
                type="button"
                phx-click="remove_meal"
                phx-value-slot_key={@slot_action.slot_key}
                data-role="remove-lunch"
                class="inline-flex items-center gap-2 rounded-[var(--r-pill)] px-3 h-8 text-[color:var(--muted)] transition-colors hover:text-[var(--text)] hover:bg-[color:var(--hairline)]"
                style="font-size: var(--t-meta);"
              >
                <.icon name="ph-x-circle" class="size-4" /> {gettext("Remove lunch")}
              </button>

              <button
                :if={!@lunch? and !Map.has_key?(@plan_state.slots, @lunch_key)}
                type="button"
                phx-click="open_lunch"
                data-role="add-lunch"
                class="inline-flex items-center gap-2 rounded-[var(--r-pill)] px-3 h-8 text-[color:var(--muted)] transition-colors hover:text-[var(--text)] hover:bg-[color:var(--hairline)]"
                style="font-size: var(--t-meta);"
              >
                <.icon name="ph-plus" class="size-4" /> {gettext("Lunch")}
              </button>

              <button
                :if={!@lunch?}
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
                  name={if @slot_action.skipped, do: "ph-x-circle", else: "ph-x-circle"}
                  class="size-4"
                />
                {if @slot_action.skipped, do: gettext("Skipped"), else: gettext("Skip dinner")}
              </button>

              <button
                :if={!@lunch?}
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
                <.icon name="ph-storefront" class="size-4" />
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
                  name={if @slot_action.pinned, do: "ph-lock", else: "ph-lock-open"}
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
                <.icon name="ph-caret-left" class="size-5" />
              </button>
              <h2 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h2);">
                {gettext("Choose a recipe")}
              </h2>
            </header>

            <div class="flex-1 overflow-y-auto px-6 pt-4 pb-6 space-y-4">
              <form phx-change="search_slot_recipes">
                <div class="relative">
                  <.icon
                    name="ph-magnifying-glass"
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
                      <.icon name="ph-lightbulb" class="size-3.5" /> {gettext("Surprise me")}
                    </button>
                  </div>

                  <ToreWeb.DishChoices.dish_choices
                    choices={@slot_action.suggestions}
                    event="pick_recipe"
                    prices={@slot_action.prices}
                    selected_id={@slot_action.selected_recipe_id}
                    loading={@slot_action.loading_suggestions}
                  />
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
  attr :price, :string, default: nil
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
        <div class="relative size-12 shrink-0 overflow-hidden rounded-[var(--r-md)]">
          <img
            :if={@recipe.image_path}
            src={~p"/images/recipes/#{@recipe.id}"}
            alt=""
            class="h-full w-full object-cover"
          />
          <.blank_cover :if={!@recipe.image_path} dish={@recipe} icon_class="size-6" />
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
        <span
          :if={@price}
          data-role="price-diff"
          class={[
            "num shrink-0 self-center",
            if(String.starts_with?(@price, "−"),
              do: "text-[color:var(--done)] font-medium",
              else: "text-[color:var(--muted)]"
            )
          ]}
          style="font-size: var(--t-meta);"
        >
          {@price}
        </span>
      </button>
    </li>
    """
  end

  # A month as weeks of seven days, Monday first; the days of the months around it are nil.
  defp load_month(socket, month) do
    scope = socket.assigns.current_scope
    first = Tore.Streams.monday(month)
    last = month |> Date.end_of_month() |> Tore.Streams.monday() |> Date.add(6)

    plans =
      Map.new(Date.range(first, last, 7), fn monday ->
        {:ok, plan_state} = Planning.load_plan(scope, plan_id(scope, monday))
        {monday, plan_state}
      end)

    weeks =
      first
      |> Date.range(last)
      |> Enum.map(fn date ->
        if date.month == month.month do
          slots = plans[Tore.Streams.monday(date)].slots
          %{date: date, slot: slots[Tore.Streams.slot_key(date)]}
        end
      end)
      |> Enum.chunk_every(7)

    assign(socket, month: month, month_weeks: weeks)
  end

  defp load_week(socket, week_start) do
    scope = socket.assigns.current_scope
    plan_id = plan_id(scope, week_start)
    {:ok, plan_state} = Planning.load_plan(scope, plan_id)

    socket
    |> assign(week_start: week_start, plan_id: plan_id)
    |> with_plan(plan_state)
  end

  defp verdict_line(%{spent: spent, budget: budget, off_by_percent: pct}) do
    spent_part =
      if budget,
        do:
          gettext("Spent %{spent} of %{budget} kr",
            spent: Tore.Money.format(spent),
            budget: Tore.Money.format(budget)
          ),
        else: gettext("Spent %{spent} kr", spent: Tore.Money.format(spent))

    cond do
      pct == nil ->
        spent_part

      pct > 0 ->
        gettext("%{spent}, about %{pct}% above the estimate", spent: spent_part, pct: pct)

      pct < 0 ->
        gettext("%{spent}, about %{pct}% below the estimate", spent: spent_part, pct: -pct)

      true ->
        gettext("%{spent}, as estimated", spent: spent_part)
    end
  end

  # The money in a few words after the dates: "about 575 of 900 kr".
  defp estimate_line(%{budget: nil} = status),
    do: gettext("about %{amount} kr", amount: Tore.Money.format(status.expected))

  defp estimate_line(%{budget: budget, over: nil} = status),
    do:
      gettext("about %{amount} of %{budget} kr",
        amount: Tore.Money.format(status.expected),
        budget: Tore.Money.format(budget)
      )

  defp estimate_line(%{budget: budget, over: over} = status),
    do:
      gettext("about %{amount} of %{budget} kr, %{over} kr over",
        amount: Tore.Money.format(status.expected),
        budget: Tore.Money.format(budget),
        over: Tore.Money.format(over)
      )

  # What each suggestion would cost on the day, as the difference from what's there now, or as an
  # amount when the day is empty. Nothing for a recipe nothing prices.
  defp suggestion_prices(socket, %{slot_key: sk, servings: servings}, suggestions) do
    %{current_scope: scope, week_start: week_start, plan_state: plan} = socket.assigns
    current_id = get_in(plan.slots, [sk, :recipe_id])
    current = current_id && Recipes.get_many(scope, [current_id])

    costs =
      Tore.Prices.recipe_costs(
        scope,
        Enum.map((current || []) ++ Enum.map(suggestions, & &1.recipe), &{&1, servings}),
        week_start
      )

    base = current_id && costs[current_id]

    Map.new(suggestions, fn %{recipe: r} ->
      {r.id, price_label(costs[r.id], base, r.id == current_id)}
    end)
  end

  defp price_label(_cost, _base, true = _already_there), do: nil
  defp price_label(nil, _base, _same), do: nil

  defp price_label(%{amount: amount, total: total}, base, _same) do
    cond do
      total == 0 or Decimal.eq?(amount, 0) ->
        nil

      base == nil or Decimal.eq?(base.amount, 0) ->
        gettext("about %{amount} kr", amount: Tore.Money.format(amount))

      true ->
        signed_kr(Decimal.sub(amount, base.amount))
    end
  end

  defp signed_kr(diff) do
    rounded = Decimal.round(diff, 0)

    cond do
      Decimal.gt?(rounded, 0) -> "+#{Tore.Money.format(rounded)} kr"
      Decimal.lt?(rounded, 0) -> "−#{Tore.Money.format(Decimal.abs(rounded))} kr"
      true -> gettext("same price")
    end
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
end
