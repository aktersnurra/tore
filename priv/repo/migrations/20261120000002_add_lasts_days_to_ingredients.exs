defmodule Tore.Repo.Migrations.AddLastsDaysToIngredients do
  use Ecto.Migration

  # How many days a pack has been seen to last, learned when the household says it's gone
  # (`Tore.Pantry.mark_gone/2`); beats Jev's guess.
  def change do
    alter table(:ingredients) do
      add :lasts_days, :integer
    end
  end
end
