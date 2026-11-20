defmodule Tore.Chats do
  @moduledoc """
  A person's conversations with pi in the chat, each its own pi session
  (`chat-<person>-<chat>`). pi keeps what was said; a chat here is its name, and when it was last
  used. The latest used is the person's current chat, which the screens' own questions go to
  (`ToreWeb.PiReply`). A chat gets its row when something is first said in it.

  pi names a chat after its first answer (`name_chat`), and the person can rename it. A
  conversation about one recipe is a session of its own (`Tore.Pi.recipe_chat_session/2`) and not
  one of these.
  """

  import Ecto.Query

  alias Tore.{Repo, Scope}
  alias Tore.Chats.Chat

  @doc "The person's chats, the latest used first."
  @spec list(Scope.t()) :: [Chat.t()]
  def list(%Scope{user_id: user_id} = scope) when is_integer(user_id) do
    from(c in Chat, where: c.user_id == ^user_id, order_by: [desc: c.updated_at, desc: c.id])
    |> Repo.all(Scope.repo_opts(scope))
  end

  @doc "The chat the person used last, or nil."
  @spec current(Scope.t()) :: Chat.t() | nil
  def current(%Scope{} = scope), do: scope |> list() |> List.first()

  @doc "One of the person's own chats, or nil."
  @spec get(Scope.t(), integer()) :: Chat.t() | nil
  def get(%Scope{user_id: user_id} = scope, id) when is_integer(user_id) and is_integer(id) do
    from(c in Chat, where: c.id == ^id and c.user_id == ^user_id)
    |> Repo.one(Scope.repo_opts(scope))
  end

  @spec create(Scope.t()) :: {:ok, Chat.t()}
  def create(%Scope{household_id: household_id, user_id: user_id})
      when is_integer(user_id),
      do: Repo.insert(%Chat{household_id: household_id, user_id: user_id})

  @doc """
  The session a screen's question goes to: the person's current chat, started when they have none,
  and marked used.
  """
  @spec asking_session(Scope.t()) :: String.t()
  def asking_session(%Scope{} = scope) do
    chat =
      case current(scope) do
        nil ->
          {:ok, chat} = create(scope)
          chat

        chat ->
          :ok = touch(scope, chat)
          chat
      end

    session(chat)
  end

  @doc "Marks the chat just used, so it's the person's current one."
  @spec touch(Scope.t(), Chat.t()) :: :ok
  def touch(%Scope{} = scope, %Chat{id: id}) do
    {1, _} =
      from(c in Chat, where: c.id == ^id)
      |> Repo.update_all([set: [updated_at: DateTime.utc_now()]], Scope.repo_opts(scope))

    :ok
  end

  @doc "Names the chat, and tells the person's other screens."
  @spec rename(Scope.t(), Chat.t(), String.t()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Scope{} = scope, %Chat{} = chat, title) do
    with {:ok, chat} <- chat |> Chat.title_changeset(title) |> Repo.update() do
      Phoenix.PubSub.broadcast(Tore.PubSub, topic(scope), {:chat_titled, chat.id, chat.title})
      {:ok, chat}
    end
  end

  @doc "The chat's pi session."
  @spec session(Chat.t()) :: String.t()
  def session(%Chat{user_id: user_id, id: id}), do: "chat-#{user_id}-#{id}"

  @doc "The person's chat a pi session belongs to, or nil for any other session."
  @spec from_session(Scope.t(), String.t() | nil) :: Chat.t() | nil
  def from_session(%Scope{user_id: user_id} = scope, session)
      when is_integer(user_id) and is_binary(session) do
    prefix = "chat-#{user_id}-"

    with ^prefix <> rest <- session,
         {id, ""} <- Integer.parse(rest) do
      get(scope, id)
    else
      _ -> nil
    end
  end

  def from_session(_scope, _session), do: nil

  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{} = scope), do: Phoenix.PubSub.subscribe(Tore.PubSub, topic(scope))

  defp topic(%Scope{household_id: household_id, user_id: user_id}),
    do: "chats:#{household_id}:#{user_id}"
end
