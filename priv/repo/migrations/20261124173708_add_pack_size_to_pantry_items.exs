defmodule Tore.Repo.Migrations.AddPackSizeToPantryItems do
  use Ecto.Migration

  # How much one pack holds, in the row's unit, so 1640 g can show as two packs of 820 g.
  def change do
    alter table(:pantry_items) do
      add :pack_size, :decimal
    end
  end
end
