defmodule Tore.Repo.Migrations.CreateUploadedImages do
  use Ecto.Migration

  def change do
    create table(:uploaded_images) do
      add :content_hash, :string, null: false
      add :stream_id, :string, null: false
      add :kind, :string, null: false
      add :household_id, references(:households, on_delete: :delete_all), null: false
      timestamps(updated_at: false)
    end

    create unique_index(:uploaded_images, [:household_id, :content_hash])
  end
end
