defmodule ToreWeb.Layouts do
  @moduledoc """
  Application layout: the page, the tab bar (`ToreWeb.TabBarLive`), and flashes.
  """
  use ToreWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true

  attr :socket, :any,
    default: nil,
    doc: "the page's socket, which renders the tab bar; without it the page has no bar"

  attr :current_user, :map, default: nil, doc: "who the tab bar is for, with `socket`"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class={[
      "min-h-screen px-4 py-4 md:px-6 md:py-6",
      @socket && "pb-28"
    ]}>
      {render_slot(@inner_block)}
    </main>

    {@socket &&
      live_render(@socket, ToreWeb.TabBarLive,
        id: "tab-bar-live",
        sticky: true,
        session: %{"user_id" => @current_user.id}
      )}

    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
