defmodule Tore.Mcp.DevToken do
  @moduledoc """
  A fixed Bearer token for `/mcp` on a developer's machine, so a harness can run against local
  Tore without Pocket ID (`.docs/specs/self-improving-harness.md`, step 0). It signs in as the
  user whose `oidc_sub` is `MCP_DEV_SUB`, `dev` by default. Compiled in dev only, and used only
  when `MCP_DEV_TOKEN` is set.
  """

  @behaviour Tore.Mcp.Token

  @impl true
  def verify(token) when is_binary(token) do
    config = Application.fetch_env!(:tore, :mcp_dev)

    if Plug.Crypto.secure_compare(token, config[:token]),
      do: {:ok, config[:sub]},
      else: {:error, :invalid_token}
  end
end
