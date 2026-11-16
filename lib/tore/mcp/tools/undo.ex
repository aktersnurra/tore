defmodule Tore.Mcp.Tools.Undo do
  @moduledoc "Undoes a change by its run id, as Undo in the app does."
  @behaviour Tore.Mcp.Tool

  alias Tore.Harness.Runs

  @impl true
  def name, do: "undo"

  @impl true
  def description,
    do:
      "Undoes a change, by the run_id a write tool answered with, whether it was made here or in the app."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"run_id" => %{"type" => "string"}},
      "required" => ["run_id"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"run_id" => id}) when is_binary(id) do
    case Runs.revert(scope, id) do
      {:ok, _run} -> {:ok, %{done: "Undone.", run_id: id}}
      {:error, :not_found} -> {:error, "No change #{id} in this household."}
      {:error, reason} -> {:error, "That change can't be undone: #{inspect(reason)}."}
    end
  end

  def call(_scope, _args), do: {:error, "undo needs the run_id a write tool answered with."}
end
