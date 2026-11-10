defmodule Tore.AccountsTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.{Accounts, Repo}
  alias Tore.Accounts.{Membership, PendingMember, User}
  alias Tore.Household.HouseholdSchema

  @claims %{"sub" => "abc", "preferred_username" => "gustaf", "name" => "Gustaf R"}

  defp memberships(user) do
    Repo.all(
      from m in Membership,
        where: m.user_id == ^user.id,
        order_by: m.household_id,
        select: {m.household_id, m.active}
    )
  end

  # Users besides Home's sponsor, seeded by test_helper.exs.
  defp user_count,
    do: Repo.aggregate(from(u in User, where: u.username != "home-sponsor"), :count)

  describe "sign_in_plan/2" do
    test "someone known is refreshed, whatever waits for them" do
      user = %User{id: 1}
      assert Accounts.sign_in_plan(user, []) == {:refresh, user}
      assert Accounts.sign_in_plan(user, [%PendingMember{}]) == {:refresh, user}
    end

    test "someone new who was added joins those households" do
      pending = [%PendingMember{household_id: 1}]
      assert Accounts.sign_in_plan(nil, pending) == {:join, pending}
    end

    test "someone new who wasn't added gets a household of their own" do
      assert Accounts.sign_in_plan(nil, []) == :new_household
    end
  end

  describe "sign_in/1" do
    test "a new person gets a household of their own, named after them, with no language yet" do
      assert {:ok, user} = Accounts.sign_in(@claims)

      assert user.oidc_sub == "abc"
      assert user.username == "gustaf"
      assert user.name == "Gustaf R"
      assert user.ai_enabled == false
      assert [{household_id, true}] = memberships(user)
      assert household_id != home_scope().household_id

      household = Repo.get!(HouseholdSchema, household_id)
      assert household.name == "Gustaf R"
      assert household.locale == nil
      assert household.ai_sponsor_id == nil
    end

    test "a new person with the credits claim sponsors their own household" do
      {:ok, user} = Accounts.sign_in(Map.put(@claims, "tore_ai", "true"))
      [{household_id, true}] = memberships(user)

      assert Repo.get!(HouseholdSchema, household_id).ai_sponsor_id == user.id
    end

    test "someone added before their first sign-in joins, in that household's language, with no household of their own" do
      english = household_fixture(%{locale: "en"})
      households_before = Repo.aggregate(HouseholdSchema, :count)
      Repo.insert!(%PendingMember{username: "gustaf", household_id: english.id})
      Repo.insert!(%PendingMember{username: "gustaf", household_id: home_scope().household_id})

      assert {:ok, user} = Accounts.sign_in(@claims)

      assert user.locale == "en"
      assert memberships(user) == [{home_scope().household_id, false}, {english.id, true}]
      assert Repo.aggregate(HouseholdSchema, :count) == households_before
      assert Repo.aggregate(PendingMember, :count) == 0
    end

    test "someone returning is the same user, with fresh claims" do
      {:ok, first} = Accounts.sign_in(@claims)

      {:ok, again} =
        Accounts.sign_in(%{
          "sub" => "abc",
          "preferred_username" => "gr",
          "name" => "G",
          "tore_ai" => true
        })

      assert again.id == first.id
      assert again.username == "gr"
      assert again.name == "G"
      assert again.ai_enabled == true
      assert user_count() == 1
      assert length(memberships(again)) == 1
    end

    test "losing the claim takes effect at the next sign-in" do
      {:ok, _} = Accounts.sign_in(Map.put(@claims, "tore_ai", "true"))

      assert {:ok, %{ai_enabled: false}} = Accounts.sign_in(@claims)
    end

    test "falls back to the username when there's no name" do
      for claims <- [Map.delete(@claims, "name"), %{@claims | "name" => "  "}] do
        assert {:ok, %{name: "gustaf"}} = Accounts.sign_in(claims)
      end
    end

    test "refuses claims with no username" do
      for claims <- [
            Map.delete(@claims, "preferred_username"),
            %{@claims | "preferred_username" => ""}
          ] do
        assert {:error, :username_missing} = Accounts.sign_in(claims)
      end

      assert user_count() == 0
    end

    test "refuses a username held by another identity, and leaves no household behind" do
      {:ok, _} = Accounts.sign_in(@claims)
      households = Repo.aggregate(HouseholdSchema, :count)

      assert {:error, :username_taken} = Accounts.sign_in(%{@claims | "sub" => "someone-else"})
      assert user_count() == 1
      assert Repo.aggregate(HouseholdSchema, :count) == households
    end
  end

  describe "get_session/1" do
    test "gives the user and the scope of their active household" do
      user = user_fixture()
      assert {%User{id: id}, scope} = Accounts.get_session(user.id)
      assert id == user.id
      assert scope == %Tore.Scope{household_id: home_scope().household_id, user_id: user.id}
    end

    test "a user with no active membership has no session" do
      user = user_fixture()
      Repo.delete_all(from m in Membership, where: m.user_id == ^user.id)

      assert Accounts.get_session(user.id) == nil
    end

    test "a user who is gone has no session" do
      assert Accounts.get_session(999_999) == nil
    end
  end

  test "list_members/1 lists the household's members only" do
    mine = user_fixture(name: "Ada")
    _theirs = user_fixture(name: "Bo", household: household_fixture())

    assert Enum.map(Accounts.list_members(home_scope()), & &1.username) |> Enum.sort() ==
             Enum.sort(["home-sponsor", mine.username])
  end

  test "update_preferences/2 stores preferences" do
    assert {:ok, updated} =
             Accounts.update_preferences(user_fixture(), %{preferences: %{dietary: "vegan"}})

    assert updated.preferences == %{dietary: "vegan"}
  end
end
