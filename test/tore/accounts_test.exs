defmodule Tore.AccountsTest do
  use Tore.DataCase, async: false
  alias Tore.Accounts

  describe "setup_complete?/0" do
    test "returns false when no users exist" do
      refute Accounts.setup_complete?()
    end

    test "returns true after admin is created" do
      {:ok, _} = Accounts.create_admin("Gustaf")
      assert Accounts.setup_complete?()
    end

    test "returns false with only member users" do
      {:ok, _} = Accounts.create_user(%{name: "Member"})
      refute Accounts.setup_complete?()
    end
  end

  describe "create_admin/1" do
    test "creates user with admin role and returns 16-digit code" do
      assert {:ok, {user, code}} = Accounts.create_admin("Gustaf")
      assert user.role == :admin
      assert user.name == "Gustaf"
      assert String.length(code) == 16
      assert String.match?(code, ~r/^\d{16}$/)
    end

    test "hashes the code in the database" do
      {:ok, {user, code}} = Accounts.create_admin("Gustaf")
      refute user.account_code_hash == code
      assert String.starts_with?(user.account_code_hash, "$argon2")
    end

    test "returns error for blank name" do
      assert {:error, changeset} = Accounts.create_admin("")
      assert %{name: [_ | _]} = errors_on(changeset)
    end
  end

  describe "create_user/1" do
    test "creates user with member role and returns 16-digit code" do
      assert {:ok, {user, code}} = Accounts.create_user(%{name: "Alice"})
      assert user.role == :member
      assert String.length(code) == 16
      assert String.match?(code, ~r/^\d{16}$/)
    end

    test "each code is unique" do
      {:ok, {_, code1}} = Accounts.create_admin("User1")
      {:ok, {_, code2}} = Accounts.create_user(%{name: "User2"})
      refute code1 == code2
    end
  end

  describe "authenticate/1" do
    test "returns user for correct code" do
      {:ok, {user, code}} = Accounts.create_admin("Gustaf")
      assert {:ok, authed} = Accounts.authenticate(code)
      assert authed.id == user.id
    end

    test "returns error for wrong code" do
      {:ok, _} = Accounts.create_admin("Gustaf")
      assert {:error, :invalid_code} = Accounts.authenticate("0000000000000000")
    end

    test "strips spaces from code" do
      {:ok, {_user, code}} = Accounts.create_admin("Gustaf")

      spaced =
        code
        |> String.graphemes()
        |> Enum.chunk_every(4)
        |> Enum.map(&Enum.join/1)
        |> Enum.join(" ")

      assert {:ok, _} = Accounts.authenticate(spaced)
    end

    test "returns error when no users exist" do
      assert {:error, :invalid_code} = Accounts.authenticate("1234567890123456")
    end
  end

  describe "update_preferences/2" do
    test "updates preferences map" do
      {:ok, {user, _}} = Accounts.create_admin("Gustaf")

      assert {:ok, updated} =
               Accounts.update_preferences(user, %{preferences: %{dietary: "vegan"}})

      assert updated.preferences == %{dietary: "vegan"}
    end
  end

  describe "list_users/0" do
    test "returns all users" do
      {:ok, _} = Accounts.create_admin("A")
      {:ok, _} = Accounts.create_user(%{name: "B"})
      assert length(Accounts.list_users()) == 2
    end
  end

  describe "get_user!/1" do
    test "returns user by id" do
      {:ok, {user, _}} = Accounts.create_admin("Gustaf")
      assert Accounts.get_user!(user.id).id == user.id
    end

    test "raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(999_999) end
    end
  end
end
