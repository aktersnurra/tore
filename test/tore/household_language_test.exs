defmodule Tore.HouseholdLanguageTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.{Prep, Repo}

  setup do
    # Straight to the column: a household's language can't change once picked.
    home_household() |> Ecto.Changeset.change(locale: "en") |> Repo.update!()
    :ok
  end

  test "a new person starts in the household's language" do
    assert user_fixture().locale == "en"
  end

  test "a prep guide is written in the household's language" do
    expect(Tore.MockLLM, :text, fn system, _user, _opts ->
      assert system =~ "into English"
      {:error, :timeout}
    end)

    assert {:error, :timeout} =
             Prep.generate_guide(
               home_scope(),
               Tore.Streams.plan(home_scope(), ~D[2026-11-02]),
               ~D[2026-11-02]
             )
  end
end
