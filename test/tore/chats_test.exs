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

  test "pi's card for a chat: a summary and tags, and a title only while it has none", %{
    scope: scope
  } do
    {:ok, chat} = Chats.create(scope)
    :ok = Chats.subscribe(scope)

    {:ok, chat} =
      Chats.describe(scope, chat, %{
        "title" => "Lax på fredag",
        "summary" => "Laxpasta till fredag, utan grädde.",
        "tags" => ["lax", " Fredag ", ""]
      })

    assert {chat.title, chat.summary, chat.tags} ==
             {"Lax på fredag", "Laxpasta till fredag, utan grädde.", ["lax", "fredag"]}

    assert_received {:chat_titled, _, "Lax på fredag"}

    # The person's own title stays.
    {:ok, chat} = Chats.rename(scope, chat, "Fredagsmiddag")
    {:ok, chat} = Chats.describe(scope, chat, %{"title" => "Något annat", "summary" => "Ny."})
    assert {chat.title, chat.summary} == {"Fredagsmiddag", "Ny."}
  end

  test "search finds a person's chats by title, tags and summary, best first", %{scope: scope} do
    card = fn title, summary, tags ->
      {:ok, chat} = Chats.create(scope)

      {:ok, chat} =
        Chats.describe(scope, chat, %{"title" => title, "summary" => summary, "tags" => tags})

      chat
    end

    lax = card.("Lax på fredag", "Laxpasta utan grädde.", ["fisk"])
    soppa = card.("Soppor i veckan", "Två soppor, en med lax.", ["soppa"])
    _budget = card.("Budgeten", "Veckobudget 1 400 kr.", ["pengar"])
    {:ok, _theirs} = Chats.create(scope_fixture(user_fixture()))

    assert Enum.map(Chats.search(scope, "lax"), & &1.id) == [lax.id, soppa.id]
    assert Enum.map(Chats.search(scope, "FISK"), & &1.id) == [lax.id]
    assert Chats.search(scope, "tacos") == []
    assert length(Chats.search(scope, "  ")) == 3
  end
end
