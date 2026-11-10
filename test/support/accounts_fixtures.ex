defmodule Tore.AccountsFixtures do
  @moduledoc "Users, households and scopes for tests. Users are made the way real ones are: by signing in."

  alias Tore.Scope

  @doc """
  Someone who has signed in, as a member of `:household` (default: `home_household/0`). They were added
  by username first, the way a member joins, so sign-in creates no household of their own.
  """
  def user_fixture(attrs \\ []) do
    id = System.unique_integer([:positive])
    username = "user-#{id}"
    household = Keyword.get_lazy(attrs, :household, &home_household/0)

    Tore.Repo.insert!(%Tore.Accounts.PendingMember{
      username: username,
      household_id: household.id
    })

    {:ok, user} =
      Tore.Accounts.sign_in(%{
        "sub" => "sub-#{id}",
        "preferred_username" => username,
        "name" => Keyword.get(attrs, :name, "Test User")
      })

    user
  end

  @doc "A household of its own, apart from the one people sign in to."
  def household_fixture(attrs \\ %{}) do
    {:ok, household} =
      Tore.Household.create_household(
        Map.merge(%{name: "Household #{System.unique_integer([:positive])}", locale: "sv"}, attrs)
      )

    household
  end

  @doc "The scope of the household people sign in to. Data a signed-in test user should see goes here."
  def home_scope, do: Scope.for_household(home_household().id)

  @doc "The household test users join: id 1, seeded by `test/test_helper.exs`."
  def home_household do
    Tore.Repo.get!(Tore.Household.HouseholdSchema, 1)
  end

  @doc "A scope for a user, or for a household with no user."
  def scope_fixture(user_or_household \\ user_fixture())

  def scope_fixture(%Tore.Accounts.User{} = user),
    do: user.id |> Tore.Accounts.get_session() |> elem(1)

  def scope_fixture(%Tore.Household.HouseholdSchema{id: id}), do: Scope.for_household(id)
end
