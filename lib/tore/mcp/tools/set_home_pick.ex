defmodule Tore.Mcp.Tools.SetHomePick do
  @moduledoc """
  Where the app opens, the quick swaps above the chat box and Today's note (`Tore.Home`), as pi
  chose.
  """
  @behaviour Tore.Mcp.Tool

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.Home
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Kinds

  @impl true
  def name, do: "set_home_pick"

  @impl true
  def description,
    do: """
    Sets the screen Tore opens on (today, plan or shop), up to three quick swaps above the \
    chat box, best first, and the one note Today shows, or none. Only for the home_pick job.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "screen" => %{"type" => "string", "enum" => Enum.map(Home.screens(), &to_string/1)},
        "swaps" => %{
          "type" => "array",
          "maxItems" => Home.max_swaps(),
          "items" => %{"type" => "string", "enum" => Enum.map(Home.swap_keys(), &to_string/1)}
        },
        "note" => %{
          "type" => ["string", "null"],
          "enum" => Enum.map(Home.note_keys(), &to_string/1) ++ [nil]
        }
      },
      "required" => ["screen", "swaps"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"screen" => screen, "swaps" => swaps} = args) when is_list(swaps) do
    with {:ok, screen} <- known(screen, Home.screens()),
         {:ok, swaps} <- all_known(swaps),
         {:ok, note} <- note(args["note"]) do
      pick = %HomePick{screen: screen, source: :model, swaps: swaps, note: note}

      case Runs.submit(scope, Kinds.HomePick, pick, %{actor: :mcp}) do
        {:ok, %KitchenRun{status: :applied}} -> {:ok, %{done: gettext("Set.")}}
        {:ok, %KitchenRun{failure_code: code}} -> {:error, "Not set: #{code}."}
        {:error, reason} -> {:error, "Not set: #{inspect(reason)}."}
      end
    end
  end

  def call(_scope, _args), do: {:error, "set_home_pick needs a screen and swaps."}

  defp known(value, atoms) do
    case Enum.find(atoms, &(to_string(&1) == value)) do
      nil -> {:error, "#{inspect(value)} isn't one of #{Enum.join(atoms, ", ")}."}
      atom -> {:ok, atom}
    end
  end

  defp note(nil), do: {:ok, nil}
  defp note(value), do: known(value, Home.note_keys())

  defp all_known(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case known(value, Home.swap_keys()) do
        {:ok, atom} -> {:cont, {:ok, acc ++ [atom]}}
        error -> {:halt, error}
      end
    end)
  end
end
