defmodule Tore.Mcp.Tools.UpdateMemory do
  @moduledoc "One batch of changes to the household's memory, under the same rules as Capture's `memory` tool."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "update_memory"

  @impl true
  def description,
    do: """
    Keeps what the household says that will still matter next week. `profile` is who they cook \
    for; `notes` is what has been learned and agreed. `add` takes content, `patch` takes \
    old_text and content, `remove` takes old_text. One short fact per entry, in the household's \
    language. Allergies belong in the app's diet settings, not here. Change an entry rather than \
    adding a second one.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "target" => %{"type" => "string", "enum" => ["profile", "notes"]},
        "operations" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 10,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "action" => %{"type" => "string", "enum" => ["add", "patch", "remove"]},
              "content" => %{"type" => "string"},
              "old_text" => %{"type" => "string"}
            },
            "required" => ["action"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["target", "operations"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"target" => target, "operations" => [_ | _] = operations})
      when target in ["profile", "notes"],
      do: Tool.reply(Dispatch.memory(target, operations, Tool.ctx(scope)))

  def call(_scope, _args),
    do: {:error, "update_memory needs target (profile or notes) and at least one operation."}
end
