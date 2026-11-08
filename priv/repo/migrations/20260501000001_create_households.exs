defmodule Tore.Repo.Migrations.CreateHouseholds do
  use Ecto.Migration

  def change do
    create table(:households) do
      add :name, :string, null: false
      add :locale, :string, null: false, default: "sv"
      timestamps()
    end

    # The one household, until sign-in creates one per person.
    execute(
      "INSERT INTO households (name, locale, inserted_at, updated_at) VALUES ('Home', 'sv', datetime('now'), datetime('now'))",
      ""
    )
  end
end
