defmodule Tore.Accounts do
  import Ecto.Query
  alias Tore.{Repo, Scope}
  alias Tore.Accounts.{Membership, PendingMember, User}
  alias Tore.Household.HouseholdSchema

  @type sign_in_error :: :username_missing | :username_taken | Ecto.Changeset.t()

  @doc """
  The user a session belongs to, and the scope of their active household. Read on every request, so a
  membership removed since the last one takes effect at once.
  """
  @spec get_session(term()) :: {User.t(), Scope.t()} | nil
  def get_session(user_id) do
    from(u in User,
      join: m in Membership,
      on: m.user_id == u.id and m.active,
      where: u.id == ^user_id,
      select: {u, m.household_id}
    )
    |> Repo.one()
    |> case do
      nil -> nil
      {user, household_id} -> {user, %Scope{household_id: household_id, user_id: user.id}}
    end
  end

  @doc "The members of the scope's household, by name."
  @spec list_members(Scope.t()) :: [User.t()]
  def list_members(%Scope{household_id: household_id}) do
    Repo.all(
      from u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        where: m.household_id == ^household_id,
        order_by: u.name
    )
  end

  @doc """
  What a sign-in does, from whether the person is already a user and the households waiting for their
  username. The one place the sign-in table from the households spec lives.
  """
  @spec sign_in_plan(User.t() | nil, [PendingMember.t()]) ::
          {:refresh, User.t()} | {:join, [PendingMember.t()]} | :new_household
  def sign_in_plan(%User{} = user, _pending), do: {:refresh, user}
  def sign_in_plan(nil, [_ | _] = pending), do: {:join, pending}
  def sign_in_plan(nil, []), do: :new_household

  @doc """
  Signs in whoever Pocket ID vouches for, from the claims of their ID token. Someone returning gets their
  claims refreshed. A new person joins the households they were added to, or gets one of their own.
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

    pending = Repo.all(from p in PendingMember, where: p.username == ^username, order_by: p.id)

    Repo.transaction(fn ->
      case sign_in_plan(Repo.get_by(User, oidc_sub: sub), pending) do
        {:refresh, user} ->
          user |> User.sign_in_changeset(attrs) |> Repo.update() |> or_rollback()

        {:join, pending} ->
          join_pending(attrs, pending)

        :new_household ->
          start_household(attrs)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, sign_in_error(changeset)}
    end
  end

  def sign_in(_claims), do: {:error, :username_missing}

  @doc "The language the app speaks to the user in."
  @spec set_locale(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_locale(%User{} = user, locale) do
    user
    |> Ecto.Changeset.cast(%{locale: locale}, [:locale])
    |> Ecto.Changeset.validate_inclusion(:locale, ~w(sv en))
    |> Repo.update()
  end

  @spec update_preferences(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(user, attrs) do
    user
    |> User.preferences_changeset(attrs)
    |> Repo.update()
  end

  # A member of every household that added them, active in the first, in its language.
  defp join_pending(attrs, [first | _] = pending) do
    locale = Repo.get!(HouseholdSchema, first.household_id).locale
    user = insert_user(attrs, locale)

    for p <- pending do
      Repo.insert!(%Membership{
        user_id: user.id,
        household_id: p.household_id,
        active: p.id == first.id
      })
    end

    Repo.delete_all(from p in PendingMember, where: p.id in ^Enum.map(pending, & &1.id))
    user
  end

  # A household of their own, named after them. Its language is picked at /welcome. Someone with the
  # credits claim spends them here unless they turn it off.
  defp start_household(attrs) do
    user = insert_user(attrs, nil)

    household =
      Repo.insert!(%HouseholdSchema{
        name: user.name,
        ai_sponsor_id: if(user.ai_enabled, do: user.id)
      })

    Repo.insert!(%Membership{user_id: user.id, household_id: household.id, active: true})
    user
  end

  defp insert_user(attrs, locale) do
    %User{locale: locale || "sv"}
    |> User.sign_in_changeset(attrs)
    |> Repo.insert()
    |> or_rollback()
  end

  defp or_rollback({:ok, value}), do: value
  defp or_rollback({:error, changeset}), do: Repo.rollback(changeset)

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
