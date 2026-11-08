defmodule Tore.Prep.PrepGuide do
  use Ecto.Schema
  import Ecto.Changeset

  schema "prep_guides" do
    field :household_id, :integer
    field :week_start, :date
    field :instructions, :string
    field :timeline, {:array, :map}
    field :cascade_map, :map
    field :storage_notes, :string
    field :daily_assembly, :map
    field :prep_session, :map
    timestamps()
  end

  def changeset(guide, attrs) do
    guide
    |> cast(attrs, [
      :week_start,
      :instructions,
      :timeline,
      :cascade_map,
      :storage_notes,
      :daily_assembly,
      :prep_session
    ])
    |> validate_required([:week_start])
  end
end
