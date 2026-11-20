defmodule Tore.Repo.Migrations.AddLastsToIngredients do
  use Ecto.Migration

  # How long a pack lasts in the household, as Jev judged it (`Tore.Pantry.Lasts`): only for
  # cooking, or eaten between meals over days, a week or weeks.
  def change do
    alter table(:ingredients) do
      add :lasts, :string
      add :lasts_confidence, :float
    end
  end
end
