defmodule ToreWeb.Components.ReceiptLive do
  use ToreWeb, :live_component

  alias Tore.Harness.KitchenRun
  alias Tore.Harness.Artifact.PlanDiff

  @impl true
  def update(%{run: run} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:header_text, header_for(run))
     |> assign(:body_html, body(run))
     |> assign(:body_lines, body_lines(run))
     |> assign(:focus_param, focus_param(run))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rounded-2xl border border-[color:var(--hairline)] bg-[color:var(--surface-raised)] p-4">
      <p class="text-[10px] font-semibold text-[color:var(--accent)] uppercase tracking-widest mb-1">
        {@header_text}
      </p>
      <div class="text-sm text-[color:var(--ink)]">
        <ul :if={@body_lines} class="space-y-1">
          <li :for={line <- @body_lines} class="flex gap-2">
            <span class="text-[color:var(--subtle)]">·</span>
            <span>{line}</span>
          </li>
        </ul>
        <span :if={is_nil(@body_lines)}>{Phoenix.HTML.raw(@body_html)}</span>
      </div>
      <.link
        :if={@focus_param}
        navigate={~p"/plan?focus=#{@focus_param}"}
        class="mt-3 inline-block text-xs font-semibold text-[color:var(--accent)]"
      >
        {gettext("Edit the plan")}
      </.link>
    </div>
    """
  end

  # Header per (kind, state-variant) ------------------------------------------

  defp header_for(%KitchenRun{kind: "planner_command_run", status: status}),
    do: planner_header(status)

  defp header_for(_), do: gettext("Tore")

  defp planner_header(:running), do: gettext("Tore is working on it")
  defp planner_header(:needs_user), do: gettext("Tore needs a moment")
  defp planner_header(:applied), do: gettext("Tore adjusted the plan")
  defp planner_header(:failed), do: gettext("Tore couldn't update the plan")
  defp planner_header(:reverted), do: gettext("Reverted")
  defp planner_header(:discarded), do: gettext("Tore")

  # Body per state-variant ----------------------------------------------------

  defp body(%KitchenRun{status: :running, phase: phase}), do: escape(phase_label(phase))
  defp body(%KitchenRun{status: :needs_user, question: q}), do: escape(q)
  defp body(%KitchenRun{status: :failed, failure_code: code}), do: escape(failure_message(code))
  defp body(%KitchenRun{status: :reverted}), do: escape(gettext("Changes reverted."))
  defp body(_), do: ""

  defp failure_message(:slot_pinned),
    do: gettext("That day is pinned, so Tore left it as it was.")

  defp failure_message(:servings_missing),
    do: gettext("A meal was missing servings, so nothing was changed.")

  defp failure_message(:skip_not_explicit),
    do: gettext("Tore couldn't tell which day to skip.")

  defp failure_message(:leftover_no_source),
    do: gettext("There was no earlier meal to make leftovers from.")

  defp failure_message(:dietary_violation),
    do: gettext("A suggested recipe didn't fit your household's needs.")

  defp failure_message(:near_duplicate),
    do: gettext("You already have a recipe just like this one.")

  defp failure_message(code)
       when code in [
              :missing_title,
              :missing_instructions,
              :no_ingredients,
              :empty_ingredient_name
            ],
       do: gettext("That recipe came back incomplete — nothing was saved.")

  defp failure_message(:interrupted),
    do: gettext("Tore was restarted before it finished — nothing was changed.")

  defp failure_message(:internal_error),
    do: gettext("Tore couldn't finish that — nothing was changed.")

  defp failure_message(_),
    do: gettext("Tore couldn't finish that.")

  defp focus_param(%KitchenRun{status: :failed, repair_action: {:edit_plan, slots}}),
    do: Enum.join(slots, ",")

  defp focus_param(_), do: nil

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp phase_label(:gathering_context), do: gettext("Gathering context")
  defp phase_label(:proposing), do: gettext("Proposing")
  defp phase_label(:verifying), do: gettext("Verifying")
  defp phase_label(nil), do: gettext("Proposing")

  # Applied runs render a list of per-change lines; other variants use body/1.
  defp body_lines(%KitchenRun{status: :applied} = run), do: applied_lines(run)
  defp body_lines(_), do: nil

  defp applied_lines(%KitchenRun{artifacts: artifacts}) do
    case Enum.find(artifacts, &match?(%PlanDiff{}, &1)) do
      %PlanDiff{} = diff ->
        case PlanDiff.summarise(diff) do
          [] -> [gettext("No changes")]
          rollup -> Enum.map(rollup, &line_for/1)
        end

      nil ->
        [gettext("No changes")]
    end
  end

  defp line_for(%{change: :added, label: label, slot_key: sk})
       when is_binary(label) and label != "",
       do: gettext("Added %{recipe} on %{day}", recipe: label, day: day_of(sk))

  defp line_for(%{change: :added, slot_key: sk}),
    do: gettext("Added a meal on %{day}", day: day_of(sk))

  defp line_for(%{change: :swapped, label: label, slot_key: sk})
       when is_binary(label) and label != "",
       do: gettext("Swapped in %{recipe} on %{day}", recipe: label, day: day_of(sk))

  defp line_for(%{change: :swapped, slot_key: sk}),
    do: gettext("Swapped %{day}", day: day_of(sk))

  defp line_for(%{change: :skipped, slot_key: sk}),
    do: gettext("Skipped %{day}", day: day_of(sk))

  defp line_for(%{change: :removed, slot_key: sk}),
    do: gettext("Cleared %{day}", day: day_of(sk))

  defp line_for(%{change: :leftover, slot_key: sk}),
    do: gettext("Leftovers on %{day}", day: day_of(sk))

  defp line_for(%{change: :servings, slot_key: sk}),
    do: gettext("Adjusted servings on %{day}", day: day_of(sk))

  defp day_of(slot_key), do: slot_key |> String.split("_", parts: 2) |> hd() |> day_name()

  defp day_name("mon"), do: gettext("Monday")
  defp day_name("tue"), do: gettext("Tuesday")
  defp day_name("wed"), do: gettext("Wednesday")
  defp day_name("thu"), do: gettext("Thursday")
  defp day_name("fri"), do: gettext("Friday")
  defp day_name("sat"), do: gettext("Saturday")
  defp day_name("sun"), do: gettext("Sunday")
  defp day_name(other), do: String.capitalize(other)
end
