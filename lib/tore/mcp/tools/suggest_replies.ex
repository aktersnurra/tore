defmodule Tore.Mcp.Tools.SuggestReplies do
  @moduledoc """
  pi's suggestions for what the person might say next, shown as pills above the chat box until
  they write. Nothing is saved: they follow the latest answer and are gone with the next message.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Pi

  @max 3
  @max_length 60

  @impl true
  def name, do: "suggest_replies"

  @impl true
  def description,
    do: """
    At the end of each answer in a chat with someone, up to #{@max} short things they might say \
    next, written as they would say them, in the household's language ("Lägg den på fredag", \
    "Gör den vegetarisk"). They show as buttons above the chat box; tapping one sends it. Only \
    in a chat with someone, never in a background job.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "replies" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => @max}
      },
      "required" => ["replies"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{user_id: user_id, pi_session: "chat-" <> _ = session} = scope, %{
        "replies" => replies
      })
      when is_integer(user_id) and is_list(replies) do
    replies =
      for reply <- replies,
          is_binary(reply),
          reply = String.trim(reply),
          reply != "",
          do: String.slice(reply, 0, @max_length)

    replies = Enum.take(replies, @max)

    # Said the way pi's own events are, so a screen listening to the chat lets it pass.
    event = %{"type" => "tore_suggestions", "replies" => replies}
    Phoenix.PubSub.broadcast(Tore.PubSub, Pi.topic(scope, session), {:pi, session, event})

    {:ok, %{shown: length(replies)}}
  end

  def call(%{pi_session: "chat-" <> _}, _args),
    do: {:error, "suggest_replies needs replies, a list of short texts."}

  def call(_scope, _args),
    do: {:error, "suggest_replies is for a chat with someone, and this session isn't one."}
end
