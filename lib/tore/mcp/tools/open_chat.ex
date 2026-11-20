defmodule Tore.Mcp.Tools.OpenChat do
  @moduledoc """
  Opens one of the person's earlier chats in their tray, in place of the one pi is in. A chat that
  was only a lookup, with no card yet, is let go of, so asking for an old chat doesn't leave one
  behind.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Chats

  @impl true
  def name, do: "open_chat"

  @impl true
  def description,
    do: """
    Opens the person's earlier chat with this id (from find_chats) in their chat, in place of \
    this one, so they carry on there. Say which one you opened in a few words. When several fit, \
    ask which with suggest_replies, their titles as the replies, before opening one.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"id" => %{"type" => "integer"}},
      "required" => ["id"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{pi_session: "chat-" <> _ = from} = scope, %{"id" => id}) when is_integer(id) do
    case Chats.get(scope, id) do
      nil ->
        {:error, "No chat #{id} of theirs. Use an id from find_chats."}

      chat ->
        :ok = Chats.open(scope, from, chat.id)

        case Chats.from_session(scope, from) do
          %{title: nil} = lookup when lookup.id != chat.id -> :ok = Chats.delete(scope, lookup)
          _kept -> :ok
        end

        {:ok, %{opened: chat.title}}
    end
  end

  def call(%{pi_session: "chat-" <> _}, _args), do: {:error, "open_chat needs an id."}
  def call(_scope, _args), do: {:error, "open_chat is for a chat with someone."}
end
