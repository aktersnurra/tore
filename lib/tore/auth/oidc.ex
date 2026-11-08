defmodule Tore.Auth.Oidc do
  @moduledoc """
  Pocket ID over OIDC: the authorization code flow with PKCE, through `oidcc`.

  A behaviour, so the callback controller can be tested without a provider:

      config :tore, :oidc_module, MyStub
  """

  @provider_name Tore.Auth.OidcProvider

  @type claims :: %{String.t() => term()}

  @callback authorization_url(state :: String.t(), pkce_verifier :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback fetch_claims(code :: String.t(), pkce_verifier :: String.t()) ::
              {:ok, claims()} | {:error, term()}

  @behaviour __MODULE__

  @doc "The configured implementation. Defaults to this module."
  def impl, do: Application.get_env(:tore, :oidc_module, __MODULE__)

  @doc "The name the provider-configuration worker is registered under."
  def provider_name, do: @provider_name

  @doc "True when issuer, client ID and secret are all set."
  def configured? do
    cfg = Application.get_env(:tore, :oidc, [])
    Enum.all?([:issuer, :client_id, :client_secret], &(is_binary(cfg[&1]) and cfg[&1] != ""))
  end

  @impl __MODULE__
  def authorization_url(state, pkce_verifier) do
    cfg = config()

    case Oidcc.create_redirect_url(provider_name(), cfg[:client_id], cfg[:client_secret], %{
           redirect_uri: cfg[:redirect_uri],
           scopes: ["openid", "profile"],
           state: state,
           pkce_verifier: pkce_verifier,
           require_pkce: true
         }) do
      {:ok, url} -> {:ok, IO.iodata_to_binary(url)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl __MODULE__
  def fetch_claims(code, pkce_verifier) do
    cfg = config()

    case Oidcc.retrieve_token(code, provider_name(), cfg[:client_id], cfg[:client_secret], %{
           redirect_uri: cfg[:redirect_uri],
           pkce_verifier: pkce_verifier,
           require_pkce: true
         }) do
      {:ok, %Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}} -> {:ok, claims}
      {:ok, _token} -> {:error, :missing_id_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config, do: Application.fetch_env!(:tore, :oidc)
end
