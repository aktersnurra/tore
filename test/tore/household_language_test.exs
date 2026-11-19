defmodule Tore.HouseholdLanguageTest do
  use Tore.DataCase, async: false

  alias Tore.Repo

  setup do
    # Straight to the column: a household's language can't change once picked.
    home_household() |> Ecto.Changeset.change(locale: "en") |> Repo.update!()
    :ok
  end

  test "a new person starts in the household's language" do
    assert user_fixture().locale == "en"
  end
end
