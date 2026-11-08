defmodule Tore.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :username, :string, null: false
      add :oidc_sub, :string, null: false
      add :ai_enabled, :boolean, null: false, default: false
      add :locale, :string, null: false, default: "sv"
      add :preferences, :map, null: false, default: %{}
      add :household_id, references(:households, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:oidc_sub])
  end
end
