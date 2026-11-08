defmodule Tore.MembersTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.{Accounts, Members, Repo}
  alias Tore.Accounts.Membership
  alias Tore.Household.HouseholdSchema

  # Someone who signed in without being added, so they have a household of their own.
  defp signed_in_alone(username, claims \\ %{}) do
    {:ok, user} =
      Accounts.sign_in(
        Map.merge(%{"sub" => "sub-#{username}", "preferred_username" => username}, claims)
      )

    user
  end

  defp active_household(user), do: user.id |> Accounts.get_session() |> elem(1)

  defp households(user) do
    user |> Members.list_households() |> Enum.map(&{&1.household.id, &1.active})
  end

  describe "add/2" do
    test "someone who hasn't signed in joins at their first sign-in, with no household of their own" do
      assert {:ok, {:pending, "bo"}} = Members.add(home_scope(), " bo ")
      assert [%{username: "bo"}] = Members.list_pending(home_scope())

      bo = signed_in_alone("bo")

      assert households(bo) == [{home_scope().household_id, true}]
      assert Members.list_pending(home_scope()) == []
    end

    test "someone whose only household is empty moves over, and the empty one is deleted" do
      bo = signed_in_alone("bo")
      %{household_id: theirs} = active_household(bo)

      home_household() |> Ecto.Changeset.change(locale: "en") |> Repo.update!()

      assert {:ok, {:moved, %{id: id}}} = Members.add(home_scope(), "bo")
      assert id == bo.id
      assert {%{locale: "en"}, _} = Accounts.get_session(bo.id)
      assert households(bo) == [{home_scope().household_id, true}]
      refute Repo.get(HouseholdSchema, theirs)
    end

    test "someone whose household holds data keeps it, and gets this one in their switcher" do
      bo = signed_in_alone("bo")
      theirs = active_household(bo)
      {:ok, _} = Tore.Recipes.create(theirs, %{title: "Pannkakor", recipe_type: :meal})

      assert {:ok, {:added, _}} = Members.add(home_scope(), "bo")

      assert Enum.sort(households(bo)) ==
               Enum.sort([{theirs.household_id, true}, {home_scope().household_id, false}])
    end

    test "someone whose household has another member keeps it" do
      bo = signed_in_alone("bo")
      theirs = active_household(bo)
      _partner = user_fixture(household: Repo.get!(HouseholdSchema, theirs.household_id))

      assert {:ok, {:added, _}} = Members.add(home_scope(), "bo")
      assert Repo.get(HouseholdSchema, theirs.household_id)
    end

    test "refuses someone already a member, or already added, or no username" do
      member = user_fixture()
      {:ok, _} = Members.add(home_scope(), "bo")

      assert {:error, :already_member} = Members.add(home_scope(), member.username)
      assert {:error, :already_added} = Members.add(home_scope(), "bo")
      assert {:error, :username_missing} = Members.add(home_scope(), "  ")
    end

    test "a pending addition can be taken back, only from its own household" do
      other = scope_fixture(household_fixture())
      {:ok, _} = Members.add(home_scope(), "bo")
      [pending] = Members.list_pending(home_scope())

      :ok = Members.cancel_pending(other, pending.id)
      assert [_] = Members.list_pending(home_scope())

      :ok = Members.cancel_pending(home_scope(), pending.id)
      assert Members.list_pending(home_scope()) == []
    end
  end

  describe "remove/2" do
    test "removing someone's active household makes another active; their other households are untouched" do
      bo = signed_in_alone("bo")
      theirs = active_household(bo)
      {:ok, _} = Tore.Recipes.create(theirs, %{title: "Pannkakor", recipe_type: :meal})
      {:ok, {:added, _}} = Members.add(home_scope(), "bo")
      :ok = Members.switch(bo, home_scope().household_id)
      _partner = user_fixture()

      assert :ok = Members.remove(home_scope(), bo.id)

      assert households(bo) == [{theirs.household_id, true}]
      assert Tore.Recipes.list(theirs) |> length() == 1
    end

    test "someone left with no household gets a new one, and the old one keeps its data" do
      member = user_fixture()
      _partner = user_fixture()
      {:ok, recipe} = Tore.Recipes.create(home_scope(), %{title: "Ärtsoppa", recipe_type: :meal})

      assert :ok = Members.remove(home_scope(), member.id)

      assert [{new_id, true}] = households(member)
      assert new_id != home_scope().household_id
      assert Repo.get!(HouseholdSchema, new_id).locale == nil
      assert Tore.Recipes.get(home_scope(), recipe.id)
    end

    test "a sponsor who leaves stops sponsoring" do
      sponsor = user_fixture()
      _partner = user_fixture()
      home_household() |> Ecto.Changeset.change(ai_sponsor_id: sponsor.id) |> Repo.update!()

      :ok = Members.remove(home_scope(), sponsor.id)

      assert home_household().ai_sponsor_id == nil
    end

    test "the last member can't leave, so the household's data isn't stranded" do
      bo = signed_in_alone("bo")
      theirs = active_household(bo)

      assert {:error, :last_member} = Members.remove(theirs, bo.id)
      assert households(bo) == [{theirs.household_id, true}]
    end

    test "a member can leave, and lands in another household" do
      member = user_fixture()
      _partner = user_fixture()

      assert :ok = Members.remove(home_scope(), member.id)
      assert [{id, true}] = households(member)
      assert id != home_scope().household_id
    end

    test "only a member can be removed" do
      outsider = signed_in_alone("bo")
      assert {:error, :not_member} = Members.remove(home_scope(), outsider.id)
    end
  end

  describe "switch/2" do
    test "one household is active at a time, and the scope follows it" do
      bo = signed_in_alone("bo")
      theirs = active_household(bo)
      {:ok, _} = Tore.Recipes.create(theirs, %{title: "Pannkakor", recipe_type: :meal})
      {:ok, {:added, _}} = Members.add(home_scope(), "bo")

      assert :ok = Members.switch(bo, home_scope().household_id)

      assert active_household(bo).household_id == home_scope().household_id

      assert Repo.aggregate(
               from(m in Membership, where: m.user_id == ^bo.id and m.active),
               :count
             ) ==
               1
    end

    test "refuses a household the user isn't in" do
      bo = signed_in_alone("bo")
      assert {:error, :not_member} = Members.switch(bo, home_scope().household_id)
    end
  end

  describe "sponsorship" do
    alias Tore.Household

    defp with_claim(user), do: user |> Ecto.Changeset.change(ai_enabled: true) |> Repo.update!()

    test "a member with the claim can sponsor, and a partner shares it" do
      sponsor = with_claim(user_fixture())
      partner = user_fixture()

      {:ok, _} = Household.set_ai_sponsor(scope_fixture(sponsor), sponsor, true)

      assert Household.ai_sponsor(scope_fixture(partner)).id == sponsor.id
    end

    test "nobody can sponsor for someone else, or without the claim" do
      with_claim = with_claim(user_fixture())
      without = user_fixture()

      assert {:error, :not_allowed} =
               Household.set_ai_sponsor(scope_fixture(without), with_claim, true)

      assert {:error, :not_allowed} =
               Household.set_ai_sponsor(scope_fixture(without), without, true)

      assert Household.ai_sponsor(home_scope()) == nil
    end

    test "adding someone with the claim doesn't sponsor the household" do
      _bo = signed_in_alone("bo", %{"tore_ai" => true})
      Repo.insert!(%Tore.Recipes.Recipe{household_id: 1, title: "x", recipe_type: :meal})

      {:ok, _} = Members.add(home_scope(), "bo")

      assert Household.ai_sponsor(home_scope()) == nil
    end

    test "losing the claim or leaving stops it" do
      sponsor = with_claim(user_fixture())
      _partner = user_fixture()
      {:ok, _} = Household.set_ai_sponsor(scope_fixture(sponsor), sponsor, true)

      lost = sponsor |> Ecto.Changeset.change(ai_enabled: false) |> Repo.update!()
      assert Household.ai_sponsor(home_scope()) == nil

      with_claim(lost)
      assert Household.ai_sponsor(home_scope()).id == sponsor.id

      :ok = Members.remove(home_scope(), sponsor.id)
      assert Household.ai_sponsor(home_scope()) == nil
    end

    test "turning it off stops it" do
      sponsor = with_claim(user_fixture())
      scope = scope_fixture(sponsor)
      {:ok, _} = Household.set_ai_sponsor(scope, sponsor, true)

      {:ok, _} = Household.set_ai_sponsor(scope, sponsor, false)

      assert Household.ai_sponsor(scope) == nil
    end
  end
end
