defmodule Tore.AccountsFixtures do
  @moduledoc "Users, households and scopes for tests. Users are made the way real ones are: by signing in."

  alias Tore.Scope

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

  @doc "The household people sign in to: the first one, seeded by the migrations."
  def home_household do
    import Ecto.Query
    Tore.Repo.one!(from h in Tore.Household.HouseholdSchema, order_by: h.id, limit: 1)
  end

  @doc "A scope for a user, or for a household with no user."
  def scope_fixture(user_or_household \\ user_fixture())
  def scope_fixture(%Tore.Accounts.User{} = user), do: Scope.for_user(user)
  def scope_fixture(%Tore.Household.HouseholdSchema{id: id}), do: Scope.for_household(id)
end
