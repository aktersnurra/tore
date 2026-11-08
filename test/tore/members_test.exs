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

      assert :ok = Members.remove(home_scope(), bo.id)

      assert households(bo) == [{theirs.household_id, true}]
      assert Tore.Recipes.list(theirs) |> length() == 1
    end

    test "someone left with no household gets a new one, and the old one keeps its data" do
      member = user_fixture()
      {:ok, recipe} = Tore.Recipes.create(home_scope(), %{title: "Ärtsoppa", recipe_type: :meal})

      assert :ok = Members.remove(home_scope(), member.id)

      assert [{new_id, true}] = households(member)
      assert new_id != home_scope().household_id
      assert Repo.get!(HouseholdSchema, new_id).locale == nil
      assert Tore.Recipes.get(home_scope(), recipe.id)
    end

    test "a sponsor who leaves stops sponsoring" do
      sponsor = user_fixture()
      home_household() |> Ecto.Changeset.change(ai_sponsor_id: sponsor.id) |> Repo.update!()

      :ok = Members.remove(home_scope(), sponsor.id)

      assert home_household().ai_sponsor_id == nil
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
end
