defmodule Tore.AccountsFixtures do
  @moduledoc "Users for tests, made the way real ones are: by signing in."

  def user_fixture(attrs \\ []) do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Tore.Accounts.sign_in(%{
        "sub" => "sub-#{id}",
        "preferred_username" => "user-#{id}",
        "name" => Keyword.get(attrs, :name, "Test User")
      })

    user
  end
end
