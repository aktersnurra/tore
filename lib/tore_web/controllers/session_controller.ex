defmodule ToreWeb.SessionController do
  use ToreWeb, :controller

  alias ToreWeb.UserSession

  def new(conn, _params) do
    if get_session(conn, :user_id) do
      redirect(conn, to: ~p"/")
    else
      render(conn, :new)
    end
  end

  def delete(conn, _params) do
    conn
    |> UserSession.log_out()
    |> redirect(to: ~p"/login")
  end
end
