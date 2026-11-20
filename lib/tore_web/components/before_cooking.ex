defmodule ToreWeb.BeforeCooking do
  @moduledoc """
  The sheet Cook now opens when Tore thinks something isn't at home. Tick what you do have; say
  what you'd use instead and Kolla asks pi once for all of it, in the person's chat: pi answers
  with `suggest_swaps` (`Tore.Recipes.Swaps`). Then cook with the swaps, or anyway. The swaps
  travel to cook mode in its address. Nothing is saved.

  The screen hands pi's events to `forward/1` while the sheet is open, since only it hears them.

      <.live_component
        module={ToreWeb.BeforeCooking}
        id="before-cooking"
        scope={@current_scope}
        recipe={@recipe}
        missing={@home.missing}
        cook_params={[servings: 4, from: "/today"]}
        on_close="close_before_cooking"
      />
  """

  use ToreWeb, :live_component

  alias Tore.Pi
  alias Tore.Recipes.Swaps

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       had: MapSet.new(),
       offered: "",
       swaps: nil,
       checking: false,
       failed: nil,
       listed: MapSet.new()
     )}
  end

  @impl true
  def update(%{pi_event: event}, socket), do: {:ok, pi_event(event, socket)}

  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(ai?: Pi.check(assigns.scope) == :ok)}
  end

  @doc "One of pi's events, from the screen the sheet is on."
  def forward(event), do: send_update(__MODULE__, id: "before-cooking", pi_event: event)

  defp pi_event(%{"type" => "tool_execution_end", "isError" => false} = event, socket) do
    with %{checking: true} <- socket.assigns,
         "mcp__tore__suggest_swaps" <- event["toolName"],
         %{"content" => [%{"type" => "text", "text" => text} | _]} <- event["result"],
         {:ok, %{"swaps" => swaps}} when is_list(swaps) <- Jason.decode(text) do
      assign(socket,
        swaps: Swaps.for_missing(still_missing(socket.assigns), swaps),
        checking: false
      )
    else
      _ -> socket
    end
  end

  # pi finished without swaps: it couldn't, or it answered in words only.
  defp pi_event(%{"type" => type}, %{assigns: %{checking: true}} = socket)
       when type in ["agent_settled", "exited"],
       do: assign(socket, failed: failure(nil), checking: false)

  defp pi_event(_event, socket), do: socket

  @impl true
  def handle_event("tick", %{"name" => name}, socket) do
    had = socket.assigns.had
    had = if name in had, do: MapSet.delete(had, name), else: MapSet.put(had, name)
    {:noreply, assign(socket, had: had, swaps: nil, failed: nil)}
  end

  def handle_event("check", %{"offered" => offered}, socket) do
    %{scope: scope, recipe: recipe} = socket.assigns

    case still_missing(socket.assigns) do
      [] ->
        {:noreply, socket}

      missing ->
        message =
          "From the sheet before cooking #{recipe.title} (recipe #{recipe.id}): these aren't at " <>
            "home: #{Enum.join(missing, ", ")}. They have: \"#{String.trim(offered)}\". " <>
            "Give a swap for each with suggest_swaps, then say it in a sentence."

        # The screen hears the answer and hands it on (`forward/1`).
        session = Pi.screen_session(scope)
        :ok = ToreWeb.PiReply.listen(scope, session)

        case Pi.ask(scope, session, message) do
          :ok ->
            {:noreply, assign(socket, offered: offered, checking: true, swaps: nil, failed: nil)}

          {:error, reason} ->
            {:noreply, assign(socket, offered: offered, failed: failure(reason))}
        end
    end
  end

  def handle_event("put_on_list", %{"name" => name}, socket) do
    scope = socket.assigns.scope
    list_id = Tore.Streams.shop_list(scope, Tore.Streams.monday(Tore.Clock.today()))
    Tore.Shop.add_item(scope, list_id, name, nil, nil, scope.user_id)
    {:noreply, update(socket, :listed, &MapSet.put(&1, name))}
  end

  defp failure(reason) do
    Tore.Pi.refusal_text(reason) || gettext("Couldn't check. Nothing has changed.")
  end

  defp still_missing(%{missing: missing, had: had}), do: Enum.reject(missing, &(&1 in had))

  # Cook mode's address, with the swaps that have something to use.
  defp cook_path(recipe, params, swaps) do
    swaps = Enum.filter(swaps || [], & &1.use)
    ~p"/recipes/#{recipe.id}/cook?#{params ++ to_param(swaps)}"
  end

  @doc "Swaps as cook mode's `?swaps=`: none adds nothing."
  @spec to_param([map()]) :: keyword()
  def to_param([]), do: []

  def to_param(swaps) do
    [
      swaps:
        swaps
        |> Enum.with_index()
        |> Map.new(fn {swap, i} ->
          {to_string(i),
           Map.reject(
             %{"for" => swap.for, "use" => swap.use, "note" => swap.note},
             &is_nil(elem(&1, 1))
           )}
        end)
    ]
  end

  @doc """
  Swaps back from the address, keeping only what makes sense there: a name for a name, a short
  note, a dozen at most.
  """
  @spec from_param(term()) :: [%{for: String.t(), use: String.t(), note: String.t() | nil}]
  def from_param(%{} = param) do
    param
    |> Enum.sort_by(fn {i, _} ->
      with {n, ""} <- Integer.parse(to_string(i)), do: n, else: (_ -> 0)
    end)
    |> Enum.flat_map(fn
      {_i, %{"for" => for, "use" => use} = swap} when is_binary(for) and is_binary(use) ->
        [%{for: short(for, 60), use: short(use, 60), note: short(swap["note"], 200)}]

      _ ->
        []
    end)
    |> Enum.take(12)
  end

  def from_param(_param), do: []

  defp short(text, max) when is_binary(text), do: String.slice(text, 0, max)
  defp short(_text, _max), do: nil

  defp swap_for(nil, _name), do: nil
  defp swap_for(swaps, name), do: Enum.find(swaps, &(&1.for == name))

  attr :swap, :map, required: true
  attr :listed, :boolean, required: true
  attr :target, :any, required: true

  # Under a missing thing: what to use instead, and how; or that nothing fits, and the list.
  defp swap_line(assigns) do
    ~H"""
    <div
      class="settle pb-1 pl-8 text-[color:var(--muted)]"
      style="font-size: 14.5px; line-height: 1.45;"
      data-role="swap"
    >
      <p :if={@swap.use} class="flex flex-wrap items-center gap-x-2">
        <span class="font-semibold text-[color:var(--text)]">
          <.icon name="ph-arrow-right" class="size-3.5" /> {@swap.use}
        </span>
        <span :if={@swap.at_home} class="tag tag-green">{gettext("At home")}</span>
      </p>
      <p :if={@swap.note}>{@swap.note}</p>
      <p :if={!@swap.use and !@swap.note}>{gettext("Nothing at home fits.")}</p>
      <button
        :if={!@swap.use and !@listed}
        type="button"
        phx-click="put_on_list"
        phx-value-name={@swap.for}
        phx-target={@target}
        class="press mt-0.5 font-semibold text-[color:var(--accent-ink)] hover:underline"
      >
        {gettext("Put on the list")}
      </button>
      <p :if={@listed} class="settle font-semibold text-[color:var(--done)]">
        <.icon name="ph-check" class="size-3.5" /> {gettext("On the list")}
      </p>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :left, still_missing(assigns))

    ~H"""
    <div>
      <.bottom_sheet id={@id} on_close={@on_close}>
        <div class="overflow-y-auto px-5" data-role="before-cooking">
          <h2 class="t-title">{gettext("Before you start")}</h2>
          <p class="mt-1 text-[color:var(--muted)]" style="font-size: 15px;">
            {gettext("Tore can't find these at home. Tick what you have.")}
          </p>

          <ul class="mt-3">
            <li
              :for={name <- @missing}
              class={["tick-row py-1", name in @had && "is-checked"]}
              data-missing={name}
            >
              <button
                type="button"
                role="checkbox"
                aria-checked={to_string(name in @had)}
                phx-click="tick"
                phx-value-name={name}
                phx-target={@myself}
                class="press press-soft flex min-h-11 w-full items-center gap-3 text-left"
              >
                <span class="tick-box">
                  <svg viewBox="0 0 24 24" aria-hidden="true">
                    <path d="M5.5 12.5l4.2 4.2L18.5 8" />
                  </svg>
                </span>
                <span class="text-[color:var(--text)]" style="font-size: 16px;">{name}</span>
              </button>

              <.swap_line
                :if={name not in @had and swap_for(@swaps, name)}
                swap={swap_for(@swaps, name)}
                listed={name in @listed}
                target={@myself}
              />
            </li>
          </ul>

          <form
            :if={@ai? and @left != []}
            id={"#{@id}-check"}
            phx-submit="check"
            phx-target={@myself}
            class="mt-4"
          >
            <label for={"#{@id}-offered"} class="t-eyebrow">
              {gettext("Have something instead?")}
            </label>
            <div class="mt-2 flex items-start gap-2">
              <.field
                id={"#{@id}-offered"}
                name="offered"
                value={@offered}
                placeholder={gettext("e.g. red onion, sour cream")}
                autocomplete="off"
                class="min-w-0 flex-1"
              />
              <button
                type="submit"
                class="pill pill-lg press"
                disabled={@checking}
                data-role="check-swaps"
              >
                {gettext("Check")}
              </button>
            </div>
          </form>

          <p
            :if={@checking}
            role="status"
            class="mt-3 flex items-center gap-2 text-[color:var(--muted)]"
            style="font-size: 14px;"
          >
            <.icon name="ph-arrows-clockwise" class="size-4 motion-safe:animate-spin" />
            {gettext("Checking what you can use…")}
          </p>
          <p
            :if={@failed}
            role="alert"
            class="mt-3 text-[color:var(--muted)]"
            style="font-size: 14px;"
          >
            {@failed}
          </p>

          <div class="mt-6 flex flex-wrap items-center gap-4">
            <.link
              :if={@left == [] or @swaps}
              navigate={cook_path(@recipe, @cook_params, @left != [] && @swaps)}
              data-role="cook-with"
              class="pill pill-lamp press"
            >
              <.icon name="ph-fire-fill" />
              {if @left == [], do: gettext("Cook now"), else: gettext("Cook with these")}
            </.link>
            <.link
              :if={@left != []}
              navigate={cook_path(@recipe, @cook_params, nil)}
              data-role="cook-anyway"
              class="press font-semibold text-[color:var(--muted)] hover:underline"
            >
              {gettext("Cook anyway")}
            </.link>
          </div>
        </div>
      </.bottom_sheet>
    </div>
    """
  end
end
