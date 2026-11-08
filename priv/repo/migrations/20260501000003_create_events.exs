defmodule Tore.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :stream_id, :string, null: false
      add :stream_type, :string, null: false
      add :event_type, :string, null: false
      add :data, :text, null: false
      add :metadata, :text
      timestamps(updated_at: false)
    end

    create index(:events, [:household_id, :stream_id, :id])
  end
end
