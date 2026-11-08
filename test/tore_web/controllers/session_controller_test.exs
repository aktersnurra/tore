defmodule ToreWeb.SessionControllerTest do
  use ToreWeb.ConnCase, async: false

  alias Phoenix.Router

  test "/login is open to someone signed out", %{conn: conn} do
    assert html_response(get(conn, ~p"/login"), 200) =~ "Tore"
  end

  test "/login sends someone signed in to the app", %{conn: conn} do
    conn = conn |> Plug.Test.init_test_session(%{user_id: user_fixture().id}) |> get(~p"/login")

    assert redirected_to(conn) == ~p"/"
  end

  test "a page sends someone signed out to /login", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/recipes")) == ~p"/login"
  end

  test "a session for a user with no household is turned away", %{conn: conn} do
    import Ecto.Query
    user = user_fixture()
    Tore.Repo.delete_all(from m in Tore.Accounts.Membership, where: m.user_id == ^user.id)

    conn = conn |> Plug.Test.init_test_session(%{user_id: user.id}) |> get(~p"/recipes")

    assert redirected_to(conn) == ~p"/login"
  end

  test "signing out ends the session and closes open LiveViews", %{conn: conn} do
    user = user_fixture()
    socket_id = "users_sessions:#{user.id}"
    ToreWeb.Endpoint.subscribe(socket_id)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id, live_socket_id: socket_id})
      |> delete(~p"/logout")

    assert redirected_to(conn) == ~p"/login"
    assert conn.private.plug_session_info == :drop
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^socket_id}
  end

  test "the code login and setup routes are gone" do
    for path <- ["/setup", "/login/session"] do
      assert Router.route_info(ToreWeb.Router, "GET", path, "localhost") == :error
    end
  end

  test "the dev sign-in isn't routed outside dev" do
    assert Router.route_info(ToreWeb.Router, "GET", "/dev/login", "localhost") == :error
  end

  test "the dev sign-in signs in", %{conn: conn} do
    conn =
      conn
      |> bypass_through(ToreWeb.Router, :browser)
      |> get("/")
      |> ToreWeb.DevSessionController.create(%{})

    assert redirected_to(conn) == ~p"/"

    assert get_session(conn, :user_id) ==
             Tore.Accounts.get_session(get_session(conn, :user_id)) |> elem(0) |> Map.fetch!(:id)

    assert get_session(conn, :live_socket_id) == "users_sessions:#{get_session(conn, :user_id)}"
  end
end
