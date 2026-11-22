defmodule Tore.Repo.Migrations.AddWithdrawnOnToDeals do
  use Ecto.Migration

  def change do
    alter table(:deals) do
      add :withdrawn_on, :date
    end
  end
end
