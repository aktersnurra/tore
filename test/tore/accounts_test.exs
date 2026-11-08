defmodule Tore.AccountsTest do
  use Tore.DataCase, async: false

  alias Tore.{Accounts, Household, Repo}
  alias Tore.Household.HouseholdSchema

  @claims %{"sub" => "abc", "preferred_username" => "gustaf", "name" => "Gustaf R"}

  describe "sign_in/1" do
    test "a new person joins the household" do
      assert {:ok, user} = Accounts.sign_in(@claims)

      assert user.oidc_sub == "abc"
      assert user.username == "gustaf"
      assert user.name == "Gustaf R"
      assert user.household_id == home_scope().household_id
      assert user.ai_enabled == false
    end

    test "a new person starts in the household's language" do
      home_household() |> HouseholdSchema.changeset(%{locale: "en"}) |> Repo.update!()

      assert {:ok, %{locale: "en"}} = Accounts.sign_in(@claims)
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
      assert length(Accounts.list_users()) == 1
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

      assert Accounts.list_users() == []
    end

    test "refuses a username held by another identity" do
      {:ok, _} = Accounts.sign_in(@claims)

      assert {:error, :username_taken} = Accounts.sign_in(%{@claims | "sub" => "someone-else"})
      assert length(Accounts.list_users()) == 1
    end
  end

  describe "get_session_user/1" do
    test "finds a user with a household" do
      user = user_fixture()
      assert Accounts.get_session_user(user.id).id == user.id
    end

    test "a user with no household has no session" do
      user = user_fixture()
      user |> Ecto.Changeset.change(household_id: nil) |> Repo.update!()

      assert Accounts.get_session_user(user.id) == nil
    end

    test "a user who is gone has no session" do
      assert Accounts.get_session_user(999_999) == nil
    end
  end

  test "update_preferences/2 stores preferences" do
    assert {:ok, updated} =
             Accounts.update_preferences(user_fixture(), %{preferences: %{dietary: "vegan"}})

    assert updated.preferences == %{dietary: "vegan"}
  end
end
