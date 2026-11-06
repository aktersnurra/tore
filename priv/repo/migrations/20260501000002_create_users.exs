defmodule Tore.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :username, :string, null: false
      add :oidc_sub, :string, null: false
      add :ai_enabled, :boolean, null: false, default: false
      add :preferences, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:oidc_sub])
  end
end
