defmodule Tore.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :username, :string, null: false
      add :oidc_sub, :string, null: false
      add :ai_enabled, :boolean, null: false, default: false
      add :locale, :string, null: false, default: "sv"
      add :preferences, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:oidc_sub])

    # The user whose credits the household may spend. Here because households come before users.
    alter table(:households) do
      add :ai_sponsor_id, references(:users, on_delete: :nilify_all)
    end

    # One row per household a user belongs to; the active one is the household they act for.
    create table(:memberships, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :household_id, references(:households, on_delete: :delete_all), primary_key: true
      add :active, :boolean, null: false, default: false
      timestamps(updated_at: false)
    end

    create index(:memberships, [:household_id])

    create unique_index(:memberships, [:user_id],
             where: "active = 1",
             name: :memberships_one_active
           )

    # Someone added by username before their first sign-in. Used up when they sign in.
    create table(:pending_members) do
      add :username, :string, null: false
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :added_by_id, references(:users, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:pending_members, [:username, :household_id])
  end
end
