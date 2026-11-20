defmodule Tore.Chats.Chat do
  @moduledoc "One of a person's conversations with pi. pi keeps what was said; this is its name."
  use Ecto.Schema
  import Ecto.Changeset

  @max_title 60

  schema "chats" do
    field :household_id, :integer
    field :user_id, :integer
    field :title, :string
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
end
