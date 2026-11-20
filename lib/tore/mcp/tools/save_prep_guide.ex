defmodule Tore.Mcp.Tools.SavePrepGuide do
  @moduledoc "The week's prep guide pi wrote, replacing the one the Prep screen shows for that week."
  @behaviour Tore.Mcp.Tool

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.Mcp.Tool
  alias Tore.Prep

  @impl true
  def name, do: "save_prep_guide"

  @impl true
  def description,
    do: """
    Saves a prep guide for a week, replacing that week's: one prep session that makes components \
    the week's dinners share. prep_session lists what to make, by kind, each "what — how" \
    ("whole chicken — roast 200°C 60 min"); timeline is the session's steps in order with their \
    minutes; daily_assembly says per dinner how to finish it from the components, and cascade_map \
    how one dinner's component feeds a later one, both keyed by date. Words in the household's \
    language.\
    """

  @strings %{"type" => "array", "items" => %{"type" => "string"}}
  @by_date %{
    "type" => "object",
    "description" => "Keyed by ISO date.",
    "additionalProperties" => %{"type" => "string"}
  }

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "week" => %{"type" => "string", "description" => "Any day in the week, as an ISO date."},
        "prep_session" => %{
          "type" => "object",
          "properties" => %{
            "proteins" => @strings,
            "bases" => @strings,
            "sauces" => @strings,
            "vegetables" => @strings
          },
          "additionalProperties" => false
        },
        "timeline" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "task" => %{"type" => "string"},
              "detail" => %{"type" => "string", "description" => "What it's for, or how."},
              "duration_min" => %{"type" => "integer", "minimum" => 0}
            },
            "required" => ["task", "duration_min"],
            "additionalProperties" => false
          }
        },
        "storage_notes" => %{
          "type" => "string",
          "description" => "How long each keeps, and where."
        },
        "daily_assembly" => @by_date,
        "cascade_map" => @by_date
      },
      "required" => ["week", "timeline"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, args) do
    with {:ok, day} <- Tool.date(args["week"]) do
      attrs =
        args
        |> Map.take(~w(prep_session timeline storage_notes daily_assembly cascade_map))
        |> Map.put("week_start", Tore.Streams.monday(day))

      case Prep.save_guide(scope, attrs) do
        {:ok, _guide} -> {:ok, %{done: gettext("Saved the prep guide.")}}
        {:error, changeset} -> {:error, "Not saved: #{inspect(changeset.errors)}."}
      end
    end
  end
end
