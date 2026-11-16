defmodule ToreWeb.McpMetadataController do
  @moduledoc """
  OAuth 2.0 protected-resource metadata (RFC 9728) for `/mcp`: Claude reads it to find Pocket ID,
  the authorization server. Served at the root and at the path-suffixed form.
  """
  use ToreWeb, :controller

  alias Tore.Mcp.Token

  def show(conn, _params) do
    if Token.enabled?() do
      json(conn, %{
        resource: ToreWeb.Endpoint.url() <> "/mcp",
        authorization_servers: [Application.fetch_env!(:tore, :oidc)[:issuer]],
        scopes_supported: ["openid", "profile"],
        bearer_methods_supported: ["header"]
      })
    else
      send_resp(conn, 404, "")
    end
  end
end
