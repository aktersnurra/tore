defmodule ToreWeb.Chef do
  @moduledoc """
  The chef on Today (`Tore.Chef`): a quiet row at the foot of the page, and a sheet with the chef
  larger, the dinners cooked and what's next. The figure is a stand-in until the chef is drawn:
  everything about it is in `figure/1` and the `Chef` hook (assets/js/chef.js), which a Lottie
  player can take over, keeping `data-stage`, `data-extras` and the taps.
  """
  use ToreWeb, :html

  # The stand-in: the cook, with what each stage holds, and the kitchen's extras in a row.
  @props %{dishwasher: "🧽", apprentice: "🥔", cook: "🔪", sous_chef: "🍳", head_chef: "🍲"}
  @extras ~w(🧄 📚 🌿 🫖 🐈 🥖)

  attr :chef, :map, required: true

  @doc "The row on Today: the chef, its stage and the dinners so far. Tapping opens the sheet."
  def chef_row(assigns) do
    ~H"""
    <section id="chef-row" class="mt-10">
      <button
        type="button"
        phx-click="open_chef"
        data-role="open-chef"
        class="press press-soft flex w-full items-center gap-3 rounded-[var(--r-lg)] py-2 text-left"
      >
        <.figure id="chef-small" chef={@chef} size={:small} />
        <span class="min-w-0">
          <span class="block font-semibold">{stage_name(@chef.stage)}</span>
          <span class="num block text-[13px] text-[color:var(--muted)]">
            {dinners(@chef.dinners)}
          </span>
        </span>
      </button>
      <%!-- Said once on this phone, when the chef has moved up since it was last seen here --%>
      <p
        data-chef-up
        hidden
        class="settle mt-1 font-semibold text-[color:var(--accent-ink)]"
        style="font-size: 15px;"
      >
        {gettext("Tore is %{stage} now", stage: String.downcase(stage_name(@chef.stage)))}
      </p>
    </section>
    """
  end

  attr :chef, :map, required: true

  @doc "The chef's sheet: larger, saying a line when tapped; the dinners, and what's next."
  def chef_sheet(assigns) do
    ~H"""
    <.bottom_sheet id="chef-sheet" on_close="close_chef">
      <div class="flex flex-col items-center px-5 pt-2 pb-4 text-center">
        <.figure id="chef-large" chef={@chef} size={:large} lines={lines()} />
        <p class="t-head mt-3">{stage_name(@chef.stage)}</p>
        <p class="num mt-2 text-[color:var(--muted)]" style="font-size: 15px;">
          {dinners(@chef.dinners)}
        </p>
        <p
          :if={@chef.rescued > 0}
          class="num mt-1 text-[color:var(--muted)]"
          style="font-size: 15px;"
        >
          {ngettext(
            "1 of them used food that would otherwise have gone off",
            "%{count} of them used food that would otherwise have gone off",
            @chef.rescued
          )}
        </p>
        <p :if={@chef.next} class="num mt-4" style="font-size: 15px;">
          {next(@chef.next)}
        </p>
      </div>
    </.bottom_sheet>
    """
  end

  attr :id, :string, required: true
  attr :chef, :map, required: true
  attr :size, :atom, values: [:small, :large], required: true
  attr :lines, :list, default: [], doc: "what the chef may say when tapped"

  # The figure the hook animates: idle bob, a hop and a line on a tap, the move up once.
  defp figure(assigns) do
    assigns = assign(assigns, prop: @props[assigns.chef.stage], extras: extras(assigns.chef))

    ~H"""
    <div
      id={@id}
      phx-hook="Chef"
      data-chef
      data-stage={@chef.stage}
      data-stage-index={stage_index(@chef.stage)}
      data-extras={@chef.extras}
      data-lines={Jason.encode!(@lines)}
      class={["chef relative shrink-0 select-none", "chef-#{@size}", "chef-#{@chef.stage}"]}
      aria-hidden="true"
    >
      <span
        id={"#{@id}-line"}
        phx-update="ignore"
        data-chef-line
        class="chef-line pointer-events-none absolute bottom-full left-1/2 mb-1 whitespace-nowrap rounded-[var(--r-pill)] bg-[var(--surface)] px-3 py-1 text-[14px] font-semibold text-[color:var(--text)] shadow-sm"
      >
      </span>
      <span class="chef-body">
        <span class="chef-face">🧑‍🍳</span><span class="chef-prop">{@prop}</span>
      </span>
      <span :if={@extras != []} class="chef-extras">{@extras}</span>
    </div>
    """
  end

  @stages [:dishwasher, :apprentice, :cook, :sous_chef, :head_chef]
  defp stage_index(stage), do: Enum.find_index(@stages, &(&1 == stage))

  defp extras(%{extras: count}), do: @extras |> Enum.take(count) |> Enum.join()

  defp stage_name(:dishwasher), do: gettext("Dishwasher")
  defp stage_name(:apprentice), do: gettext("Apprentice")
  defp stage_name(:cook), do: gettext("Cook")
  defp stage_name(:sous_chef), do: gettext("Sous chef")
  defp stage_name(:head_chef), do: gettext("Head chef")

  defp dinners(count),
    do: ngettext("1 dinner cooked at home", "%{count} dinners cooked at home", count)

  defp next(%{stage: :extra, left: left}),
    do: gettext("%{count} more to something new in the kitchen", count: left)

  defp next(%{stage: stage, left: left}),
    do: gettext("%{count} more to %{stage}", count: left, stage: stage_name(stage))

  # What a tap makes the chef say.
  defp lines do
    [
      gettext("Yes, chef!"),
      gettext("What are we cooking tonight?"),
      gettext("Taste it first!"),
      gettext("A pinch more salt?"),
      gettext("The dishes won't wait.")
    ]
  end
end
