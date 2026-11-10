defmodule Tore.Repo.Migrations.CreateHouseholds do
  use Ecto.Migration

  def change do
    create table(:households) do
      add :name, :string, null: false
      # Picked once, at /welcome, by the household's first member.
      add :locale, :string
      timestamps()
    end
  end
end
