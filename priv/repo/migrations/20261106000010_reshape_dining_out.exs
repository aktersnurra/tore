defmodule Tore.Repo.Migrations.ReshapeDiningOut do
  use Ecto.Migration

  # Eating out is now a state of a day in the plan: the amount is optional, and
  # a row links to its slot. SQLite can't drop NOT NULL in place, so rebuild the
  # table. Older rows have no slot link and stay as they are.
  def up do
    create table(:dining_out_new) do
      add :date, :date, null: false
      add :description, :string
      add :total_amount, :decimal
      add :plan_id, :string
      add :slot_key, :string
      add :user_id, references(:users, on_delete: :nothing), null: false
      timestamps()
    end

    execute """
    INSERT INTO dining_out_new (id, date, description, total_amount, user_id, inserted_at, updated_at)
    SELECT id, date, description, total_amount, user_id, inserted_at, updated_at
    FROM dining_out
    """

    drop table(:dining_out)
    rename table(:dining_out_new), to: table(:dining_out)

    create index(:dining_out, [:user_id])
    create index(:dining_out, [:date])
    create unique_index(:dining_out, [:plan_id, :slot_key])
  end

  def down, do: raise(Ecto.MigrationError, message: "num_people is gone for good")
end
