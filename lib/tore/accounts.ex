defmodule Tore.Accounts do
  import Ecto.Query
  alias Tore.Repo
  alias Tore.Accounts.User

  @spec setup_complete?() :: boolean()
  def setup_complete? do
    Repo.exists?(from u in User, where: u.role == :admin)
  end

  @spec get_user!(term()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(User)

  @spec create_admin(String.t()) :: {:ok, {User.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_admin(name), do: create_with_role(name, :admin)

  @spec create_user(map()) :: {:ok, {User.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) when is_map(attrs) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name", "")
    create_with_role(name, :member)
  end

  @spec authenticate(String.t()) :: {:ok, User.t()} | {:error, :invalid_code}
  def authenticate(code) when is_binary(code) do
    normalized = String.replace(code, ~r/\D/, "")

    Repo.all(User)
    |> Enum.find_value({:error, :invalid_code}, fn user ->
      if Argon2.verify_pass(normalized, user.account_code_hash), do: {:ok, user}
    end)
  end

  @spec regenerate_code(User.t()) :: {:ok, {User.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def regenerate_code(user) do
    code = generate_code()
    hash = Argon2.hash_pwd_salt(code)

    user
    |> User.registration_changeset(%{name: user.name, role: user.role, account_code_hash: hash})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, {updated, code}}
      {:error, cs} -> {:error, cs}
    end
  end

  @spec update_preferences(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(user, attrs) do
    user
    |> User.preferences_changeset(attrs)
    |> Repo.update()
  end

  defp create_with_role(name, role) do
    code = generate_code()
    hash = Argon2.hash_pwd_salt(code)

    %User{}
    |> User.registration_changeset(%{
      name: name,
      role: role,
      account_code_hash: hash,
      locale: Tore.Household.locale()
    })
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, {user, code}}
      {:error, cs} -> {:error, cs}
    end
  end

  defp generate_code do
    :crypto.strong_rand_bytes(16)
    |> :binary.bin_to_list()
    |> Enum.map(&rem(&1, 10))
    |> Enum.map(&Integer.to_string/1)
    |> Enum.join()
  end
end
