defmodule Tore.Chats.Chat do
  @moduledoc """
  One of a person's conversations with pi. pi keeps what was said; this is its card: a title, a
  line or two of what it's about and a few tags, which finding it again searches.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_title 60
  @max_summary 300
  @max_tags 6

  schema "chats" do
    field :household_id, :integer
    field :user_id, :integer
    field :title, :string
    field :summary, :string
    field :tags, {:array, :string}, default: []
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "A new title: trimmed, cut to #{@max_title} characters, never blank."
  def title_changeset(chat, title) do
    title = title |> to_string() |> String.trim() |> String.slice(0, @max_title)

    chat
    |> change(title: title)
    |> validate_required([:title])
  end

  @doc """
  pi's card: the summary and tags, cleaned and kept short, and the title only while the chat has
  none, so a title the person gave stays.
  """
  def card_changeset(chat, attrs) do
    summary = attrs["summary"] |> to_string() |> String.trim() |> String.slice(0, @max_summary)

    tags =
      for(
        tag <- List.wrap(attrs["tags"]),
        is_binary(tag),
        tag = tag |> String.trim() |> String.downcase(),
        tag != "",
        do: tag
      )
      |> Enum.uniq()
      |> Enum.take(@max_tags)

    changeset = chat |> change(summary: summary, tags: tags) |> validate_required([:summary])

    case {chat.title, attrs["title"]} do
      {nil, title} when is_binary(title) -> title_changeset(changeset, title)
      _ -> changeset
    end
  end
end
