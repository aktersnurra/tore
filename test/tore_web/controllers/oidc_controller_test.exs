defmodule ToreWeb.OidcControllerTest do
  use ToreWeb.ConnCase, async: false

  alias Tore.Accounts.User
  alias Tore.Repo

  defmodule StubOidc do
    @behaviour Tore.Auth.Oidc

    @impl true
    def authorization_url(state, _verifier),
      do: {:ok, "https://pocket-id.test/authorize?state=#{state}"}

    @impl true
    def fetch_claims("good-code", "vf"),
      do:
        {:ok,
         %{
           "sub" => "sub-alice",
           "preferred_username" => "alice",
           "name" => "Alice",
           "tore_ai" => true
         }}

    def fetch_claims("impostor-code", "vf"),
      do: {:ok, %{"sub" => "sub-impostor", "preferred_username" => "alice"}}

    def fetch_claims("no-username-code", "vf"), do: {:ok, %{"sub" => "sub-anon"}}
    def fetch_claims(_code, _verifier), do: {:error, :invalid_grant}
  end

  setup do
    Application.put_env(:tore, :oidc_module, StubOidc)
    on_exit(fn -> Application.delete_env(:tore, :oidc_module) end)
    :ok
  end

  defp callback(conn, params, session \\ %{oidc_state: "st", oidc_pkce_verifier: "vf"}) do
    conn |> Plug.Test.init_test_session(session) |> get(~p"/auth/oidc/callback", params)
  end

  test "/login offers Pocket ID", %{conn: conn} do
    assert html_response(get(conn, ~p"/login"), 200) =~ ~s(href="/auth/oidc")
  end

  test "GET /auth/oidc sends the browser to Pocket ID and keeps state and verifier", %{conn: conn} do
    conn = get(conn, ~p"/auth/oidc")
    state = get_session(conn, :oidc_state)

    assert redirected_to(conn) == "https://pocket-id.test/authorize?state=#{state}"
    assert get_session(conn, :oidc_pkce_verifier)
  end

  test "a first sign-in creates the member and signs them in", %{conn: conn} do
    conn = callback(conn, %{"code" => "good-code", "state" => "st"})

    assert redirected_to(conn) == ~p"/"
    user = Repo.get_by!(User, oidc_sub: "sub-alice")
    assert %User{username: "alice", name: "Alice", ai_enabled: true} = user
    assert get_session(conn, :user_id) == user.id
    refute get_session(conn, :oidc_state)
    refute get_session(conn, :oidc_pkce_verifier)
  end

  test "signing in again keeps the same member", %{conn: conn} do
    callback(conn, %{"code" => "good-code", "state" => "st"})
    conn = callback(build_conn(), %{"code" => "good-code", "state" => "st"})

    assert get_session(conn, :user_id) == Repo.get_by!(User, oidc_sub: "sub-alice").id
    assert Repo.aggregate(User, :count) == 1
  end

  test "a state that doesn't match is refused", %{conn: conn} do
    conn = callback(conn, %{"code" => "good-code", "state" => "forged"})

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
    refute Repo.get_by(User, oidc_sub: "sub-alice")
  end

  test "a callback with no sign-in in progress is refused", %{conn: conn} do
    conn = callback(conn, %{"code" => "good-code", "state" => "st"}, %{})

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
  end

  test "a state that isn't a string is refused, not a crash", %{conn: conn} do
    conn = callback(conn, %{"code" => "good-code", "state" => ["st"]})

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
  end

  test "without Pocket ID configured, /login hides the button", %{conn: conn} do
    oidc = Application.fetch_env!(:tore, :oidc)
    Application.put_env(:tore, :oidc, Keyword.put(oidc, :client_secret, nil))
    on_exit(fn -> Application.put_env(:tore, :oidc, oidc) end)

    refute html_response(get(conn, ~p"/login"), 200) =~ ~s(href="/auth/oidc")
    assert redirected_to(get(build_conn(), ~p"/auth/oidc")) == ~p"/login"
  end

  test "an error from Pocket ID goes back to /login", %{conn: conn} do
    conn = callback(conn, %{"error" => "access_denied", "state" => "st"})

    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error)
  end

  test "a code Pocket ID won't exchange is refused", %{conn: conn} do
    conn = callback(conn, %{"code" => "bad-code", "state" => "st"})

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
  end

  test "claims without a username are refused", %{conn: conn} do
    conn = callback(conn, %{"code" => "no-username-code", "state" => "st"})

    assert redirected_to(conn) == ~p"/login"
    refute Repo.get_by(User, oidc_sub: "sub-anon")
  end

  test "a username held by another Pocket ID account is refused", %{conn: conn} do
    callback(conn, %{"code" => "good-code", "state" => "st"})
    conn = callback(build_conn(), %{"code" => "impostor-code", "state" => "st"})

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
    refute Repo.get_by(User, oidc_sub: "sub-impostor")
  end

  test "GET /auth/oidc goes back to /login when Pocket ID can't be reached", %{conn: conn} do
    Application.put_env(:tore, :oidc_module, __MODULE__.Unreachable)
    conn = get(conn, ~p"/auth/oidc")

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :oidc_state)
  end

  defmodule Unreachable do
    @behaviour Tore.Auth.Oidc
    @impl true
    def authorization_url(_state, _verifier), do: {:error, :provider_not_ready}
    @impl true
    def fetch_claims(_code, _verifier), do: {:error, :provider_not_ready}
  end
end
