defmodule ToreWeb.Chef do
  @moduledoc """
  The chef (`Tore.Chef`): at most one on a page, doing what the page is for. On Today, a quiet row
  at the foot of the page and a sheet with him larger, the dinners cooked and what's next; at the
  stove while cooking; with his cart on Shop; at his desk on the budget page.

  Each scene is one of pi's drawings, priv/static/images/chef/<scene>.svg, with all five stages,
  breathing and blinking by itself. The `Chef` hook (assets/js/chef.js) puts it in, picks the
  stage, and plays his reactions.
  """
  use ToreWeb, :html

  attr :chef, :map, required: true
  attr :scene, :atom, required: true, doc: "what he's doing, from `Tore.Chef.today_scene/1`"
  attr :stir, :boolean, default: false, doc: "stirring a pot instead, while Tore is answering"

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
        <.figure id="chef-small" stage={@chef.stage} scene={@scene} stir={@stir} size={:small} />
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
  attr :scene, :atom, required: true
  attr :lines, :list, required: true, doc: "what the chef may say when tapped: about the day"

  @doc "The chef's sheet: larger, saying a line when tapped; the dinners, and what's next."
  def chef_sheet(assigns) do
    ~H"""
    <.bottom_sheet id="chef-sheet" on_close="close_chef">
      <div class="flex flex-col items-center px-5 pt-2 pb-4 text-center">
        <.figure id="chef-large" stage={@chef.stage} scene={@scene} size={:large} lines={@lines} />
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
        <%!-- Things in the kitchen past the last stage aren't drawn yet, so they go unsaid --%>
        <p :if={@chef.next && @chef.next.stage != :extra} class="num mt-4" style="font-size: 15px;">
          {next(@chef.next)}
        </p>
      </div>
    </.bottom_sheet>
    """
  end

  attr :id, :string, required: true
  attr :stage, :atom, required: true, doc: "the household's stage, from `Tore.Chef.now/1`"

  attr :scene, :atom,
    values: [:chef, :sleep, :morning, :list, :stove, :cart, :desk],
    default: :chef,
    doc: "what he's doing: one drawing each, except asleep, which is the plain chef's pose"

  attr :size, :atom, values: [:small, :large], required: true
  attr :lines, :list, default: [], doc: "what the chef may say when tapped"

  attr :mood, :string,
    default: nil,
    doc: "one reaction when he's put in: \"proud\", \"cheer\" or \"pleased\""

  attr :stir, :boolean, default: false, doc: "stirring a pot instead, while Tore is answering"
  attr :class, :any, default: nil

  # The figure the hook draws the chef in: its own shadow root, so the drawing's styles and ids
  # stay apart from the page's.
  @doc "The chef himself, in a scene. A page shows one at most."
  def figure(assigns) do
    assigns =
      assign(assigns,
        drawing:
          if(assigns.stir or assigns.scene in [:chef, :sleep],
            do: "chef.svg",
            else: "#{assigns.scene}.svg"
          )
      )

    ~H"""
    <div
      id={@id}
      phx-hook="Chef"
      data-chef
      data-src={~p"/images/chef/#{@drawing}"}
      data-scene={@scene}
      data-sleep={@scene == :sleep and not @stir}
      data-stage={@stage}
      data-stage-index={stage_index(@stage)}
      data-lines={Jason.encode!(@lines)}
      data-mood={@mood}
      data-stir={@stir}
      data-wake-line={gettext("Mm… I was having a nap.")}
      class={["chef relative shrink-0 select-none", "chef-#{@size}", @class]}
      aria-hidden="true"
    >
      <span
        id={"#{@id}-line"}
        phx-update="ignore"
        data-chef-line
        class="chef-line pointer-events-none absolute bottom-full left-1/2 mb-1 whitespace-nowrap rounded-[var(--r-pill)] bg-[var(--surface)] px-3 py-1 text-[14px] font-semibold text-[color:var(--text)] shadow-sm"
      >
      </span>
      <span id={"#{@id}-art"} phx-update="ignore" data-chef-art class="chef-art"></span>
    </div>
    """
  end

  @stages [:dishwasher, :apprentice, :cook, :sous_chef, :head_chef]
  defp stage_index(stage), do: Enum.find_index(@stages, &(&1 == stage))

  @doc "The stage's name, as the household's language says it."
  def stage_name(:dishwasher), do: gettext("Dishwasher")
  def stage_name(:apprentice), do: gettext("Apprentice")
  def stage_name(:cook), do: gettext("Cook")
  def stage_name(:sous_chef), do: gettext("Sous chef")
  def stage_name(:head_chef), do: gettext("Head chef")

  defp dinners(count),
    do: ngettext("1 dinner cooked at home", "%{count} dinners cooked at home", count)

  defp next(%{stage: stage, left: left}),
    do: gettext("%{count} more to %{stage}", count: left, stage: stage_name(stage))
end
