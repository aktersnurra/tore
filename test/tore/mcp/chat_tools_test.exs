defmodule Tore.Mcp.ChatToolsTest do
  use Tore.DataCase, async: true

  alias Tore.{Chats, Pi}
  alias Tore.Mcp.SessionToken
  alias Tore.Mcp.Tools.{DescribeChat, FindChats, OpenChat, SuggestReplies}

  setup do
    scope = scope_fixture(user_fixture())
    {:ok, chat} = Chats.create(scope)
    # What pi's session token signs in as: the person, and which of their sessions it is.
    {:ok, in_chat} = SessionToken.verify(SessionToken.mint(scope, Chats.session(chat), 60))
    %{scope: scope, chat: chat, in_chat: in_chat}
  end

  test "a session token says which session it is", %{in_chat: in_chat, chat: chat} do
    assert in_chat.pi_session == Chats.session(chat)
  end

  describe "describe_chat" do
    test "writes the card of the chat pi is in", %{scope: scope, chat: chat, in_chat: in_chat} do
      assert {:ok, %{title: "Middag i helgen"}} =
               DescribeChat.call(in_chat, %{
                 "title" => "Middag i helgen",
                 "summary" => "Tacos lördag, pizza söndag.",
                 "tags" => ["helg", "tacos"]
               })

      assert %{title: "Middag i helgen", tags: ["helg", "tacos"]} = Chats.get(scope, chat.id)
    end

    test "is refused outside a person's chat", %{scope: scope} do
      {:ok, about_recipe} =
        SessionToken.verify(SessionToken.mint(scope, Pi.recipe_chat_session(scope, 7), 60))

      assert {:error, _} =
               DescribeChat.call(about_recipe, %{"title" => "Lax", "summary" => "Lax."})

      {:ok, job} = SessionToken.verify(SessionToken.mint(scope, "finish_recipe-3", 60))
      assert {:error, _} = DescribeChat.call(job, %{"title" => "Lax", "summary" => "Lax."})
    end
  end

  describe "finding and opening an earlier chat" do
    defp earlier(scope, title, summary) do
      {:ok, chat} = Chats.create(scope)
      {:ok, chat} = Chats.describe(scope, chat, %{"title" => title, "summary" => summary})
      chat
    end

    test "find_chats gives the person's other chats' cards, best match first", %{
      scope: scope,
      in_chat: in_chat
    } do
      lax = earlier(scope, "Lax på fredag", "Laxpasta utan grädde.")
      _budget = earlier(scope, "Budgeten", "1 400 kr i veckan.")

      assert {:ok, %{chats: [card]}} = FindChats.call(in_chat, %{"query" => "lax"})
      assert %{id: id, title: "Lax på fredag", summary: "Laxpasta utan grädde."} = card
      assert id == lax.id
    end

    test "open_chat switches the tray, and lets go of the chat it was asked from", %{
      scope: scope,
      chat: lookup,
      in_chat: in_chat
    } do
      lax = earlier(scope, "Lax på fredag", "Laxpasta.")
      :ok = Chats.subscribe(scope)
      from = Chats.session(lookup)

      assert {:ok, %{opened: "Lax på fredag"}} = OpenChat.call(in_chat, %{"id" => lax.id})
      assert_received {:open_chat, ^from, id} when id == lax.id

      # The lookup had no card of its own, so it doesn't stay in the list.
      assert Chats.get(scope, lookup.id) == nil
    end

    test "open_chat keeps a chat that's more than a lookup, and opens only their own", %{
      scope: scope,
      chat: chat,
      in_chat: in_chat
    } do
      {:ok, _} = Chats.rename(scope, chat, "Veckan")
      lax = earlier(scope, "Lax", "Lax.")
      {:ok, _} = OpenChat.call(in_chat, %{"id" => lax.id})
      assert Chats.get(scope, chat.id)

      {:ok, theirs} = Chats.create(scope_fixture(user_fixture()))
      assert {:error, _} = OpenChat.call(in_chat, %{"id" => theirs.id})
    end
  end

  describe "suggest_replies" do
    test "tells the chat what the person might say next", %{in_chat: in_chat, chat: chat} do
      session = Chats.session(chat)
      :ok = Pi.subscribe(in_chat, session)

      assert {:ok, %{}} =
               SuggestReplies.call(in_chat, %{
                 "replies" => ["Lägg den på fredag", "  ", "Gör den vegetarisk"]
               })

      assert_received {:pi, ^session,
                       %{
                         "type" => "tore_suggestions",
                         "replies" => ["Lägg den på fredag", "Gör den vegetarisk"]
                       }}
    end

    test "works in a recipe's chat too, and is refused in a background job", %{scope: scope} do
      session = Pi.recipe_chat_session(scope, 7)
      {:ok, about_recipe} = SessionToken.verify(SessionToken.mint(scope, session, 60))
      :ok = Pi.subscribe(scope, session)

      assert {:ok, _} = SuggestReplies.call(about_recipe, %{"replies" => ["För sex"]})
      assert_received {:pi, ^session, %{"type" => "tore_suggestions", "replies" => ["För sex"]}}

      {:ok, job} = SessionToken.verify(SessionToken.mint(home_scope(), "plan_week-1", 60))
      assert {:error, _} = SuggestReplies.call(job, %{"replies" => ["x"]})
    end
  end
end
