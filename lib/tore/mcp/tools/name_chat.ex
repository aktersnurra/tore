defmodule Tore.Mcp.Tools.NameChat do
  @moduledoc "pi names the person's chat it is in, after its first answer there (`Tore.Chats`)."
  @behaviour Tore.Mcp.Tool

  alias Tore.Chats

  @impl true
  def name, do: "name_chat"

  @impl true
  def description,
    do: """
    Names the conversation you're in with someone, after your first answer in it: two to five \
    words in the household's language saying what it's about, like "Middag i helgen". Only in a \
    person's chat; a recipe's own chat is named after the recipe.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"title" => %{"type" => "string", "minLength" => 1}},
      "required" => ["title"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"title" => title}) when is_binary(title) do
    case Chats.from_session(scope, scope.pi_session) do
      nil ->
        {:error, "name_chat names a person's chat, and this session isn't one."}

      chat ->
        case Chats.rename(scope, chat, title) do
          {:ok, chat} -> {:ok, %{named: chat.title}}
          {:error, _changeset} -> {:error, "A title needs a few words."}
        end
    end
  end

  def call(_scope, _args), do: {:error, "name_chat needs a title."}
end
