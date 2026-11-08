ExUnit.start(exclude: [:integration])

# The household test users sign in to (`Tore.AccountsFixtures.home_household/0`). Outside the sandbox, so
# its id is 1 in every test.
import Ecto.Query

unless Tore.Repo.exists?(from h in Tore.Household.HouseholdSchema, where: h.id == 1) do
  Tore.Repo.insert!(%Tore.Household.HouseholdSchema{id: 1, name: "Home", locale: "sv"})
end

Ecto.Adapters.SQL.Sandbox.mode(Tore.Repo, :manual)
{:ok, _} = Tore.Storage.Mock.start_link()
