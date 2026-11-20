defmodule Tore.Mcp.ChatToolsTest do
  use Tore.DataCase, async: true

  alias Tore.{Chats, Pi}
  alias Tore.Mcp.SessionToken
  alias Tore.Mcp.Tools.{NameChat, SuggestReplies}

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

  describe "name_chat" do
    test "names the chat pi is in", %{scope: scope, chat: chat, in_chat: in_chat} do
      assert {:ok, %{named: "Middag i helgen"}} =
               NameChat.call(in_chat, %{"title" => "Middag i helgen"})

      assert Chats.get(scope, chat.id).title == "Middag i helgen"
    end

    test "is refused outside a person's chat", %{scope: scope} do
      {:ok, about_recipe} =
        SessionToken.verify(SessionToken.mint(scope, Pi.recipe_chat_session(scope, 7), 60))

      assert {:error, _} = NameChat.call(about_recipe, %{"title" => "Lax"})

      {:ok, job} = SessionToken.verify(SessionToken.mint(scope, "finish_recipe-3", 60))
      assert {:error, _} = NameChat.call(job, %{"title" => "Lax"})
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
