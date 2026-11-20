defmodule Tore.Repo.Migrations.AddIconToIngredients do
  use Ecto.Migration

  # The emoji Jev picked for an ingredient (`Tore.Pantry.Icons`), shown on its pantry row.
  def change do
    alter table(:ingredients) do
      add :icon, :string
    end
  end
end
