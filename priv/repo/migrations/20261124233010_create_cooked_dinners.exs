defmodule Tore.Repo.Migrations.CreateCookedDinners do
  use Ecto.Migration

  # A dinner marked Done in the cook view: what the chef on Today grows from.
  def change do
    create table(:cooked_dinners) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :recipe_id, references(:recipes, on_delete: :nilify_all)
      add :cooked_on, :date, null: false
      # It used something at, near or past its best-before.
      add :rescued, :boolean, null: false, default: false
      timestamps(updated_at: false)
    end

    create index(:cooked_dinners, [:household_id])
  end
end
