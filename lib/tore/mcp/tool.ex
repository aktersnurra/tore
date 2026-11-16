defmodule Tore.Mcp.Tool do
  @moduledoc """
  One tool on Tore's MCP server. `call/2` runs as the signed-in person's household and answers with
  a map, or with a message Claude can read and act on: arguments a tool can't use are refused by
  its own clauses, never with a crash. A write goes through `Tore.Harness.Runs.submit/4`.
  """

  alias Tore.Scope

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback call(Scope.t(), map()) :: {:ok, map()} | {:error, String.t()}
end
