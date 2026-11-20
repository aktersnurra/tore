defmodule Tore.ChatsTest do
  use Tore.DataCase, async: true

  alias Tore.Chats

  setup do
    user = user_fixture()
    %{scope: scope_fixture(user), user: user}
  end

  test "a person's chats, the latest used first, and only theirs", %{scope: scope} do
    {:ok, first} = Chats.create(scope)
    {:ok, second} = Chats.create(scope)
    {:ok, _theirs} = Chats.create(scope_fixture(user_fixture()))

    assert Enum.map(Chats.list(scope), & &1.id) == [second.id, first.id]
    assert Chats.current(scope).id == second.id

    # Writing in the first again makes it the latest.
    :ok = Chats.touch(scope, first)
    assert Chats.current(scope).id == first.id
    assert Enum.map(Chats.list(scope), & &1.id) == [first.id, second.id]
  end

  test "someone with no chat has no current one", %{scope: scope} do
    assert Chats.current(scope) == nil
    assert Chats.list(scope) == []
  end

  test "a chat is found only by its own person", %{scope: scope} do
    {:ok, chat} = Chats.create(scope)
    assert Chats.get(scope, chat.id).id == chat.id
    assert Chats.get(scope_fixture(user_fixture()), chat.id) == nil
  end

  test "a chat's pi session names its person and the chat, and leads back to it", %{
    scope: scope,
    user: user
  } do
    {:ok, chat} = Chats.create(scope)
    session = Chats.session(chat)

    assert session == "chat-#{user.id}-#{chat.id}"
    assert Chats.from_session(scope, session).id == chat.id
    assert Chats.from_session(scope, "chat-#{user.id}-recipe-3") == nil
    assert Chats.from_session(scope, "finish_recipe-12") == nil
  end

  test "a title is trimmed, kept short, and said to the person's other screens", %{scope: scope} do
    {:ok, chat} = Chats.create(scope)
    :ok = Chats.subscribe(scope)

    assert {:ok, %{title: "Middag i helgen"}} = Chats.rename(scope, chat, "  Middag i helgen ")
    assert_received {:chat_titled, id, "Middag i helgen"} when id == chat.id

    {:ok, long} = Chats.rename(scope, chat, String.duplicate("a", 200))
    assert String.length(long.title) == 60

    assert {:error, %Ecto.Changeset{}} = Chats.rename(scope, chat, "   ")
  end
end
