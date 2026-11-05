defmodule Tore.Repo.Migrations.AddShelfLife do
  use Ecto.Migration

  def change do
    alter table(:ingredients) do
      add :shelf_life_days, :integer
    end

    alter table(:pantry_items) do
      add :expires_source, :string
    end
  end
end
