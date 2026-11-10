defmodule ToreWeb.Layouts do
  @moduledoc """
  Application layout + chrome (top nav, mobile bottom nav, flash group).
  """
  use ToreWeb, :html

  embed_templates "layouts/*"

  defp nav_items do
    [
      {"/today", gettext("Today"), "nav-home"},
      {"/plan", gettext("Plan"), "nav-week"},
      {"/shop", gettext("Shop"), "nav-shop"}
    ]
  end

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :current_path, :string, default: "/"
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav_items, nav_items())

    ~H"""
    <header class="sticky top-0 z-40 hidden md:flex h-[var(--nav-height)] items-center justify-center bg-[var(--bg)]/80 backdrop-blur border-b border-[color:var(--border)]">
      <nav class="flex items-center gap-1">
        <.nav_link
          :for={{path, label, icon} <- @nav_items}
          path={path}
          current={@current_path}
          icon={icon}
          label={label}
        />
        <.nav_link
          path="/capture"
          href={~p"/capture?return_to=#{@current_path}"}
          current={@current_path}
          icon="nav-inbox"
          label={gettext("Capture")}
        />
        <.nav_link
          path="/settings"
          current={@current_path}
          icon="nav-settings"
          label={gettext("Settings")}
        />
      </nav>
    </header>

    <main class="min-h-[calc(100vh-var(--nav-height))] px-4 py-4 md:px-6 md:py-6 pb-24 md:pb-6">
      {render_slot(@inner_block)}
    </main>

    <nav
      data-role="bottom-nav"
      class="md:hidden fixed bottom-0 inset-x-0 z-40 grid grid-cols-4 bg-[var(--surface)] border-t border-[color:var(--border)]"
    >
      <%!-- fixed 4-slot bar (Today, Plan, pill, Shop) — deliberately not driven by nav_items/0; keep grid-cols in sync --%>
      <.bottom_link path="/today" current={@current_path} icon="nav-home" />
      <.bottom_link path="/plan" current={@current_path} icon="nav-week" />
      <a
        href={~p"/capture?return_to=#{@current_path}"}
        data-role="command-pill"
        aria-label={gettext("Open command tray")}
        class="flex items-center justify-center h-14"
      >
        <span class="w-12 h-7 rounded-full border border-[color:var(--border)] bg-[var(--bg)] flex items-center justify-center">
          <span class="w-5 h-1 rounded-full bg-[color:var(--muted)]"></span>
        </span>
      </a>
      <.bottom_link path="/shop" current={@current_path} icon="nav-shop" />
    </nav>

    <.flash_group flash={@flash} />
    """
  end

  attr :path, :string, required: true
  attr :href, :string, default: nil, doc: "link target when it differs from the active-state path"
  attr :current, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    assigns = assign(assigns, :active?, active?(assigns.current, assigns.path))

    ~H"""
    <a
      href={@href || @path}
      title={@label}
      aria-label={@label}
      data-active={if @active?, do: "true"}
      class={[
        "relative px-3 h-[var(--nav-height)] inline-flex items-center justify-center border-b-2 transition-colors",
        @active? && "text-[color:var(--accent)] border-[color:var(--accent)]",
        !@active? && "text-[color:var(--muted)] border-transparent hover:text-[var(--text)]"
      ]}
    >
      <.icon name={@icon} class="size-5" />
    </a>
    """
  end

  attr :path, :string, required: true
  attr :current, :string, required: true
  attr :icon, :string, required: true

  defp bottom_link(assigns) do
    assigns = assign(assigns, :active?, active?(assigns.current, assigns.path))

    ~H"""
    <a
      href={@path}
      data-active={if @active?, do: "true"}
      class={[
        "relative flex items-center justify-center h-14",
        @active? && "text-[color:var(--accent)]",
        !@active? && "text-[color:var(--muted)]"
      ]}
    >
      <.icon name={@icon} class="size-5" />
    </a>
    """
  end

  defp active?(current, "/"), do: current == "/"
  defp active?(current, path), do: String.starts_with?(current, path)

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
