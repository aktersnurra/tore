defmodule Tore.Mcp.Tools.SetBasics do
  @moduledoc "Basics the household buys beyond its dinners, under the same rules as Capture's `set_basics`."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "set_basics"

  @impl true
  def description,
    do: """
    Things the household buys every week beyond its dinners (breakfast, coffee, milk). They go \
    on each week's list when it's built, marked as basics, and into the week's estimate. Names \
    in the household's language. stop true takes them off for good. Tore also learns basics by \
    itself from what gets bought; get_context lists them.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 20,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "quantity" => %{"type" => "number", "description" => "How much a week, if known."},
              "unit" => %{"type" => "string", "description" => "g, kg, dl, l or st."}
            },
            "required" => ["name"],
            "additionalProperties" => false
          }
        },
        "stop" => %{"type" => "boolean", "default" => false}
      },
      "required" => ["items"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"items" => [_ | _] = items} = args) do
    items =
      for %{"name" => name} = item <- items, is_binary(name), String.trim(name) != "" do
        %{
          name: String.trim(name),
          quantity: Tore.Types.decimal(item["quantity"]),
          unit: item["unit"]
        }
      end

    Tool.reply(Dispatch.set_basics(items, args["stop"] == true, Tool.ctx(scope)))
  end

  def call(_scope, _args), do: {:error, "set_basics needs items, each with a name."}
end
