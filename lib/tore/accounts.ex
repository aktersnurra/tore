defmodule Tore.Accounts do
  import Ecto.Query
  alias Tore.{Household, Repo}
  alias Tore.Accounts.User

  @type sign_in_error :: :username_missing | :username_taken | Ecto.Changeset.t()

  @doc "The user a session belongs to. A user with no household has no session."
  @spec get_session_user(term()) :: User.t() | nil
  def get_session_user(id) do
    Repo.one(from u in User, where: u.id == ^id and not is_nil(u.household_id))
  end

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(User)

  @doc """
  Signs in whoever Pocket ID vouches for, from the claims of their ID token. A new person joins the
  one household and starts in its language. Someone returning gets their claims refreshed.
  """
  @spec sign_in(map()) :: {:ok, User.t()} | {:error, sign_in_error()}
  def sign_in(%{"sub" => sub, "preferred_username" => username} = claims)
      when is_binary(sub) and is_binary(username) and username != "" do
    attrs = %{
      oidc_sub: sub,
      username: username,
      name: display_name(claims["name"], username),
      ai_enabled: ai_claim?(claims)
    }

    (Repo.get_by(User, oidc_sub: sub) || new_user())
    |> User.sign_in_changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, sign_in_error(changeset)}
    end
  end

  def sign_in(_claims), do: {:error, :username_missing}

  @spec update_preferences(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(user, attrs) do
    user
    |> User.preferences_changeset(attrs)
    |> Repo.update()
  end

  defp new_user do
    household = Household.get_household!()
    %User{household_id: household.id, locale: household.locale}
  end

  defp display_name(name, username) when is_binary(name) do
    if String.trim(name) == "", do: username, else: name
  end

  defp display_name(_name, username), do: username

  # A custom claim on a Pocket ID group. The app reads the claim, never a group name.
  defp ai_claim?(claims) do
    Map.get(claims, Application.get_env(:tore, :ai_claim, "tore_ai")) in [true, "true"]
  end

  defp sign_in_error(changeset) do
    if Keyword.has_key?(changeset.errors, :username), do: :username_taken, else: changeset
  end
end
