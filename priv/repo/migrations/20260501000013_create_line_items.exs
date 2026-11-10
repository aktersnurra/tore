defmodule Tore.Repo.Migrations.CreateLineItems do
  use Ecto.Migration

  def change do
    create table(:line_items) do
      add :receipt_id, references(:receipts, on_delete: :delete_all), null: false
      add :product_name, :string, null: false
      add :category, :string
      add :quantity, :decimal
      add :unit_price, :decimal
      add :total_price, :decimal
      timestamps()
    end

    create index(:line_items, [:receipt_id])
  end
end
