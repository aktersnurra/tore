ExUnit.start(exclude: [:integration])

# The household test users sign in to (`Tore.AccountsFixtures.home_household/0`). Outside the sandbox, so
# its id is 1 in every test.
import Ecto.Query

# Home is sponsored by a member with the credits claim, so flows that call the (mocked) LLM run there.
unless Tore.Repo.exists?(from h in Tore.Household.HouseholdSchema, where: h.id == 1) do
  Tore.Repo.transaction(fn ->
    Tore.Repo.insert!(%Tore.Household.HouseholdSchema{id: 1, name: "Home", locale: "sv"})

    sponsor =
      Tore.Repo.insert!(%Tore.Accounts.User{
        name: "Home sponsor",
        username: "home-sponsor",
        oidc_sub: "home-sponsor",
        ai_enabled: true
      })

    Tore.Repo.insert!(%Tore.Accounts.Membership{
      user_id: sponsor.id,
      household_id: 1,
      active: true
    })

    Tore.Repo.update_all(from(h in Tore.Household.HouseholdSchema, where: h.id == 1),
      set: [ai_sponsor_id: sponsor.id]
    )
  end)
end

Ecto.Adapters.SQL.Sandbox.mode(Tore.Repo, :manual)
{:ok, _} = Tore.Storage.Mock.start_link()
