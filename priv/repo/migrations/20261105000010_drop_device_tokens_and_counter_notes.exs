defmodule Tore.Repo.Migrations.DropDeviceTokensAndCounterNotes do
  use Ecto.Migration

  def up do
    drop table(:device_tokens)
    drop table(:counter_notes)
  end

  def down,
    do: raise(Ecto.MigrationError, message: "device_tokens and counter_notes are gone for good")
end
