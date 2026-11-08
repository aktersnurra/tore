defmodule Tore.Repo.Migrations.CreateDiningOut do
  use Ecto.Migration

  def change do
    create table(:dining_out) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :description, :string
      add :total_amount, :decimal
      add :plan_id, :string
      add :slot_key, :string
      add :user_id, references(:users, on_delete: :nothing), null: false
      timestamps()
    end

    create index(:dining_out, [:user_id])
    create index(:dining_out, [:household_id, :date])
    create unique_index(:dining_out, [:plan_id, :slot_key])
  end
end
