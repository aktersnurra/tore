defmodule Tore.Mcp.Tools.FindChats do
  @moduledoc "The person's earlier chats whose cards match, for finding one again (`Tore.Chats.search/3`)."
  @behaviour Tore.Mcp.Tool

  alias Tore.Chats

  @max 10

  @impl true
  def name, do: "find_chats"

  @impl true
  def description,
    do: """
    Finds the person's earlier chats with you by their cards: the best #{@max} for the words in \
    query, each with its id, title, summary, tags and when it was last used. Use it when they \
    ask for an earlier conversation ("the salmon thing from last week"), then open_chat the one \
    they mean. Try a word or two the card would have, in the household's language.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{user_id: user_id} = scope, %{"query" => query})
      when is_integer(user_id) and is_binary(query) do
    here = Chats.from_session(scope, scope.pi_session)

    chats =
      for chat <- Chats.search(scope, query, @max + 1),
          chat.id != (here && here.id),
          do: %{
            id: chat.id,
            title: chat.title,
            summary: chat.summary,
            tags: chat.tags,
            last_used: chat.updated_at |> DateTime.to_date() |> Date.to_iso8601()
          }

    {:ok, %{chats: Enum.take(chats, @max)}}
  end

  def call(%{user_id: nil}, _args), do: {:error, "find_chats is for a person's chat."}
  def call(_scope, _args), do: {:error, "find_chats needs a query."}
end
