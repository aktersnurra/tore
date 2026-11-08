defmodule ToreWeb.OidcController do
  @moduledoc """
  Sign-in through Pocket ID. Pocket ID decides who may use Tore: anyone outside the
  `tore` group is refused there and never reaches the callback.
  """

  use ToreWeb, :controller

  alias Tore.Accounts
  alias Tore.Auth.Oidc
  alias ToreWeb.UserSession

  require Logger

  def request(conn, _params) do
    state = random_token()
    verifier = random_token()

    with true <- Oidc.configured?() || {:error, :not_configured},
         {:ok, url} <- Oidc.impl().authorization_url(state, verifier) do
      conn
      |> put_session(:oidc_state, state)
      |> put_session(:oidc_pkce_verifier, verifier)
      |> redirect(external: url)
    else
      {:error, reason} ->
        Logger.error("OIDC authorization URL failed: #{inspect(reason)}")
        deny(conn, gettext("Couldn't reach Pocket ID. Try again in a moment."))
    end
  end

  def callback(conn, %{"error" => error}) do
    Logger.warning("OIDC provider returned an error: #{inspect(error)}")
    deny(conn, gettext("Sign-in was cancelled or refused."))
  end

  def callback(conn, %{"code" => code, "state" => state})
      when is_binary(code) and is_binary(state) do
    session_state = get_session(conn, :oidc_state)
    verifier = get_session(conn, :oidc_pkce_verifier)

    cond do
      is_nil(session_state) or is_nil(verifier) ->
        deny(conn, gettext("Your sign-in expired. Please try again."))

      not Plug.Crypto.secure_compare(session_state, state) ->
        Logger.warning("OIDC state mismatch")
        deny(conn, gettext("Sign-in couldn't be verified. Please try again."))

      true ->
        exchange(conn, code, verifier)
    end
  end

  def callback(conn, _params), do: deny(conn, gettext("Sign-in failed. Please try again."))

  defp exchange(conn, code, verifier) do
    with {:ok, claims} <- Oidc.impl().fetch_claims(code, verifier),
         {:ok, user} <- Accounts.sign_in(claims) do
      conn
      |> UserSession.log_in(user)
      |> redirect(to: ~p"/")
    else
      {:error, :username_missing} ->
        Logger.error("OIDC sign-in refused: no preferred_username claim")
        deny(conn, gettext("Pocket ID didn't send a username."))

      {:error, :username_taken} ->
        Logger.error("OIDC sign-in refused: username already held by another identity")
        deny(conn, gettext("That username belongs to another Pocket ID account."))

      {:error, reason} ->
        Logger.error("OIDC sign-in failed: #{inspect(reason)}")
        deny(conn, gettext("Couldn't finish signing in. Please try again."))
    end
  end

  defp deny(conn, message) do
    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_pkce_verifier)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
