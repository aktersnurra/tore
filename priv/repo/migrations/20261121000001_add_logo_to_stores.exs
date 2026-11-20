defmodule Tore.Repo.Migrations.AddLogoToStores do
  use Ecto.Migration

  def change do
    alter table(:stores) do
      add :logo, :string
    end
  end
end
