defmodule Tore.Repo.Migrations.CreateReceipts do
  use Ecto.Migration

  def change do
    create table(:receipts) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :store_name, :string
      add :total_amount, :decimal
      add :image_path, :string
      add :user_id, references(:users, on_delete: :nothing), null: false
      timestamps()
    end

    create index(:receipts, [:user_id])
    create index(:receipts, [:household_id, :date])
  end
end
