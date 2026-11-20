defmodule Tore.Mcp.Tools.DescribeChat do
  @moduledoc "pi writes the card of the person's chat it is in (`Tore.Chats.describe/3`)."
  @behaviour Tore.Mcp.Tool

  alias Tore.Chats

  @impl true
  def name, do: "describe_chat"

  @impl true
  def description,
    do: """
    Writes the card of the chat you're in with someone, so they and you can find it again: a \
    title of two to five words ("Middag i helgen"), a line or two of what was talked about and \
    decided, and up to six one-word tags, all in the household's language. Call it after your \
    first answer in a chat, and again when the talk moves on to something new. The title is \
    only used while the chat has none. Not in a recipe's chat.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "summary" => %{"type" => "string", "minLength" => 1},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 6}
      },
      "required" => ["summary"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"summary" => summary} = args) when is_binary(summary) do
    case Chats.from_session(scope, scope.pi_session) do
      nil ->
        {:error, "describe_chat is for a person's chat, and this session isn't one."}

      chat ->
        case Chats.describe(scope, chat, args) do
          {:ok, chat} ->
            {:ok, %{title: chat.title}}

          {:error, _changeset} ->
            {:error, "A card needs a summary, and a title while it has none."}
        end
    end
  end

  def call(_scope, _args), do: {:error, "describe_chat needs a summary."}
end
