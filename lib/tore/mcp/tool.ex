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

  @doc "What `Tore.Capture.Dispatch` needs to act for MCP: the household, and who asked."
  @spec ctx(Scope.t()) :: Tore.Capture.Dispatch.ctx()
  def ctx(%Scope{} = scope), do: %{scope: scope, actor: :mcp}

  @doc """
  A Dispatch reply as a tool's answer: what was done and the run to undo it with, or why not.
  The text is the same Capture shows, in the household's language.
  """
  @spec reply(map()) :: {:ok, map()} | {:error, String.t()}
  def reply(%{error: true, text: text} = reply),
    do: {:error, "#{text} (#{inspect(reply[:reason])})"}

  def reply(%{rejection: rejection} = reply),
    do: {:error, String.trim("#{reply[:text]} Refused: #{inspect(rejection)}")}

  def reply(%{text: text} = reply), do: {:ok, %{done: text, run_id: reply[:run_stream_id]}}

  @doc "An ISO date argument, or a message saying what was expected."
  @spec date(term()) :: {:ok, Date.t()} | {:error, String.t()}
  def date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "date must be an ISO date, like 2026-11-18, not #{inspect(value)}."}
    end
  end

  def date(_value), do: {:error, "date is required, as an ISO date like 2026-11-18."}

  @doc "The meal a plan tool acts on: dinner unless `meal` says lunch."
  @spec meal(map()) :: Tore.Streams.meal()
  def meal(%{"meal" => "lunch"}), do: :lunch
  def meal(_args), do: :dinner
end
