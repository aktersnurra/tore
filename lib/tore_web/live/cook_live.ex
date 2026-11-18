defmodule ToreWeb.CookLive do
  @moduledoc """
  Cook mode: a recipe as cards to step through at the stove. The first card is what to take
  out; then one card per step, with what it uses and how long it takes. `?step=` holds the
  position, so a reload or the back button lands on the same card.

  `?swaps=` carries what the sheet before cooking settled on (`ToreWeb.BeforeCooking`): each
  swapped ingredient reads "rödlök instead of gul lök", with how to use it.
  """

  use ToreWeb, :live_view

  alias Tore.Recipes
  alias ToreWeb.{BeforeCooking, StepCards}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    scope = socket.assigns.current_scope
    recipe = Recipes.get!(scope, String.to_integer(id))

    # A recipe that only has running text gets its steps written by the model the first time.
    # Only once the page is live: mount also runs for the first plain render.
    if connected?(socket) do
      ToreWeb.Background.run(fn -> Recipes.cook_steps(scope, recipe) end, &{:cook_steps, &1})
    end

    {:ok,
     assign(socket,
       recipe: recipe,
       cards: nil,
       failed: false,
       overview: false,
       servings: servings(params["servings"], recipe),
       swaps: BeforeCooking.from_param(params["swaps"]),
       timers: [],
       done: nil,
       close_to: ToreWeb.SafeReturn.path(params["from"], ~p"/recipes")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :index, step_index(params["step"], socket.assigns.cards))}
  end

  @impl true
  def handle_info({:cook_steps, {:ok, steps}}, socket) do
    %{recipe: recipe, servings: servings, swaps: swaps} = socket.assigns

    cards = [
      needs_card(recipe, servings, swaps) | Enum.map(steps, &card(&1, recipe, servings, swaps))
    ]

    {:noreply, assign(socket, cards: cards, index: min(socket.assigns.index, length(cards) - 1))}
  end

  def handle_info({:cook_steps, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, failed: true)}

  @impl true
  def handle_event("step", %{"to" => to}, socket),
    do: {:noreply, go(socket, String.to_integer(to))}

  def handle_event("step_key", %{"key" => key}, socket) do
    %{index: index, cards: cards} = socket.assigns
    {:noreply, go(socket, StepCards.key_target(key, index, length(cards || [nil])))}
  end

  def handle_event("toggle_overview", _params, socket),
    do: {:noreply, update(socket, :overview, &(not &1))}

  # A timer is a deadline, so moving between steps (or a slow render) doesn't stretch it.
  def handle_event("start_timer", %{"index" => index}, socket) do
    index = String.to_integer(index)
    %{minutes: minutes} = Enum.at(socket.assigns.cards, index)

    timer = %{
      id: System.unique_integer([:positive]),
      label: gettext("Step %{n}", n: index),
      ends_at: System.system_time(:millisecond) + round(minutes * 60_000)
    }

    {:noreply, update(socket, :timers, &(&1 ++ [timer]))}
  end

  # Done: the dish was cooked tonight, and what it used is gone from the pantry, the swaps'
  # in place of what they stood for. Undo puts both back.
  def handle_event("done", _params, %{assigns: %{done: nil}} = socket) do
    %{current_scope: scope, recipe: recipe, swaps: swaps} = socket.assigns

    names =
      Enum.map(recipe.recipe_ingredients, fn ri ->
        case Enum.find(swaps, &same_name?(&1.for, ri.ingredient.name)) do
          nil -> ri.ingredient.name
          swap -> swap.use
        end
      end)

    :ok = Recipes.record_used(scope, recipe.id)
    used = Tore.Pantry.use_up(scope, names)
    # Tomorrow is what's next now, so Today's note is worth picking again.
    Tore.Home.refresh(scope)
    {:noreply, assign(socket, done: %{used: used, was: recipe.last_used_at})}
  end

  def handle_event("done", _params, socket), do: {:noreply, socket}

  def handle_event("undo_done", _params, %{assigns: %{done: %{} = done}} = socket) do
    %{current_scope: scope, recipe: recipe} = socket.assigns
    :ok = Tore.Pantry.put_back(scope, done.used)
    :ok = Recipes.record_used(scope, recipe.id, done.was)
    {:noreply, assign(socket, done: nil)}
  end

  def handle_event("stop_timer", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, update(socket, :timers, &Enum.reject(&1, fn t -> t.id == id end))}
  end

  defp done_card(nil), do: nil

  defp done_card(%{used: used}) do
    %{
      text: gettext("Cooked"),
      needs:
        if(used == [],
          do: [],
          else: [
            gettext("Used up at home: %{things}.", things: Enum.map_join(used, ", ", & &1.name))
          ]
        ),
      undo: "undo_done"
    }
  end

  defp go(socket, to) do
    %{recipe: recipe, close_to: close_to, servings: servings, swaps: swaps} = socket.assigns
    params = [step: to + 1, from: close_to, servings: servings] ++ BeforeCooking.to_param(swaps)

    socket
    |> assign(overview: false)
    |> push_patch(to: ~p"/recipes/#{recipe.id}/cook?#{params}")
  end

  # `?step=` counts from 1, like the counter on the screen.
  defp step_index(step, cards) do
    last = if cards, do: length(cards) - 1, else: 10_000

    case Integer.parse(step || "1") do
      {n, ""} when n >= 1 -> min(n - 1, last)
      _ -> 0
    end
  end

  # Servings from the recipe page's stepper; the recipe's own when there's none.
  defp servings(value, recipe) do
    case Integer.parse(value || "") do
      {n, ""} when n in 1..24 -> n
      _ -> recipe.base_servings || 4
    end
  end

  defp needs_card(recipe, servings, swaps) do
    %{
      text: gettext("Take this out"),
      needs:
        Enum.map(recipe.recipe_ingredients, fn ri ->
          ri |> ingredient_line(recipe, servings) |> swapped(ri.ingredient.name, swaps)
        end)
    }
  end

  defp card(step, recipe, servings, swaps) do
    %{
      label: step["phase"] && String.capitalize(step["phase"]),
      text: Enum.reduce(swaps, step["action"], &swap_text/2),
      minutes: positive(step["duration_minutes"]),
      needs:
        Enum.map(step["ingredients"] || [], fn name ->
          name |> need_line(recipe, servings) |> swapped(name, swaps)
        end)
    }
  end

  # "1 st gul lök" becomes "1 st rödlök instead of gul lök · Halva mängden."
  defp swapped(line, name, swaps) do
    case Enum.find(swaps, &same_name?(&1.for, name)) do
      nil ->
        line

      swap ->
        instead = gettext("%{use} instead of %{for}", use: swap.use, for: swap.for)
        line = Regex.replace(~r/#{Regex.escape(swap.for)}/iu, line, fn _ -> instead end)

        if swap.note, do: line <> " · " <> swap.note, else: line
    end
  end

  # The step's own words name the ingredient as the recipe does; they get the swap's name.
  defp swap_text(swap, text) when is_binary(text),
    do: Regex.replace(~r/#{Regex.escape(swap.for)}/iu, text, fn _ -> swap.use end)

  defp swap_text(_swap, text), do: text

  defp positive(n) when is_number(n) and n > 0, do: n
  defp positive(_), do: nil

  # A step names its ingredients; the amount comes from the recipe's own list when it's there.
  defp need_line(name, recipe, servings) do
    case Enum.find(recipe.recipe_ingredients, &same_name?(&1.ingredient.name, name)) do
      nil -> name
      ingredient -> ingredient_line(ingredient, recipe, servings)
    end
  end

  defp same_name?(a, b), do: String.downcase(a) == String.downcase(b)

  defp ingredient_line(%{quantity: nil} = ri, _recipe, _servings), do: ri.ingredient.name

  defp ingredient_line(ri, recipe, servings) do
    amount =
      ri.quantity
      |> Recipes.scale_quantity(recipe.base_servings, servings)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    Enum.join([amount, ri.unit, ri.ingredient.name] |> Enum.reject(&(&1 in [nil, ""])), " ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <StepCards.deck
        :if={@cards}
        id="cook-mode"
        title={@recipe.title}
        cards={@cards}
        index={@index}
        overview={@overview}
        close_to={@close_to}
        timers={@timers}
        on_done="done"
        done={done_card(@done)}
      />

      <div
        :if={!@cards}
        id="cook-mode-waiting"
        class="fixed inset-0 z-[60] flex flex-col justify-center bg-[var(--bg)] px-5"
      >
        <div class="mx-auto w-full max-w-2xl">
          <p class="t-eyebrow">{@recipe.title}</p>
          <p class="t-title mt-3 flex items-center gap-3" role="status">
            <.icon
              :if={!@failed}
              name="ph-arrows-clockwise"
              class="size-6 shrink-0 text-[color:var(--muted)] motion-safe:animate-spin"
            />
            {if @failed,
              do: gettext("Couldn't write the steps"),
              else: gettext("Writing the steps…")}
          </p>
          <p :if={@failed} class="mt-3 text-[color:var(--muted)]" style="font-size: var(--t-body);">
            {gettext(
              "The recipe is unchanged. Open it to read it as it is, or try again in a moment."
            )}
          </p>
          <.link
            navigate={@close_to}
            class="pill pill-lg press mt-8"
          >
            {gettext("Back")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
