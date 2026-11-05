defmodule ToreWeb.Live.Auth do
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias Tore.Accounts

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = socket |> mount_current_user(session) |> attach_current_path()

    if socket.assigns.current_user do
      household_id = household_id()

      if Phoenix.LiveView.connected?(socket) do
        Phoenix.PubSub.subscribe(Tore.PubSub, "toasts:user:#{socket.assigns.current_user.id}")
        Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:#{household_id}")
      end

      socket =
        socket
        |> assign(:inbox_count, inbox_count(household_id))
        |> attach_toast_hook()
        |> attach_inbox_count_hook(household_id)

      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = socket |> mount_current_user(session) |> attach_current_path()

    case socket.assigns.current_user do
      %{role: :admin} -> {:cont, socket}
      nil -> {:halt, redirect(socket, to: "/login")}
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  defp attach_current_path(socket) do
    socket
    |> assign(:current_path, "/")
    |> attach_hook(:current_path, :handle_params, fn _params, url, socket ->
      path = URI.parse(url).path || "/"
      {:cont, assign(socket, :current_path, path)}
    end)
  end

  defp mount_current_user(socket, session) do
    case session["user_id"] do
      nil ->
        Gettext.put_locale(ToreWeb.Gettext, "en")
        assign(socket, :current_user, nil)

      user_id ->
        user = Accounts.get_user!(user_id)
        Gettext.put_locale(ToreWeb.Gettext, user.locale || "en")
        assign(socket, :current_user, user)
    end
  rescue
    Ecto.NoResultsError ->
      Gettext.put_locale(ToreWeb.Gettext, "en")
      assign(socket, :current_user, nil)
  end

  # Per-user PubSub topic for background jobs that need to surface a result
  # toast wherever the user happens to be at the moment they complete.
  defp attach_toast_hook(socket) do
    Phoenix.LiveView.attach_hook(socket, :toasts, :handle_info, fn
      {:toast, kind, message}, socket ->
        flash_key = if kind in [:error, :danger], do: :error, else: :info
        {:halt, Phoenix.LiveView.put_flash(socket, flash_key, message)}

      _other, socket ->
        {:cont, socket}
    end)
  end

  # Keep the global :inbox_count assign in sync — every authenticated
  # LiveView shares this via @inbox_count, most visibly Today's review pill.
  defp attach_inbox_count_hook(socket, household_id) do
    Phoenix.LiveView.attach_hook(socket, :inbox_count, :handle_info, fn
      {:run_state_changed, _stream_id, _state}, socket ->
        {:cont, assign(socket, :inbox_count, inbox_count(household_id))}

      _other, socket ->
        {:cont, socket}
    end)
  end

  defp household_id, do: Tore.Household.get_household!().id

  defp inbox_count(household_id) do
    Tore.Harness.ProjectorSupervisor.start_or_lookup(household_id)
    length(Tore.Harness.Projector.list_pending(household_id))
  end
end
