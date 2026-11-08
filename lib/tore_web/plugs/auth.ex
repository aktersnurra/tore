defmodule ToreWeb.Plugs.Auth do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Tore.Accounts

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        conn |> redirect(to: "/login") |> halt()

      user_id ->
        case Accounts.get_session(user_id) do
          nil ->
            conn |> delete_session(:user_id) |> redirect(to: "/login") |> halt()

          {user, scope} ->
            conn
            |> assign(:current_user, user)
            |> assign(:current_scope, scope)
        end
    end
  end
end
