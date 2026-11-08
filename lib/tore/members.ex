defmodule Tore.Members do
  @moduledoc """
  Who shares a household: adding, removing and switching. Pocket ID decides who can sign in at all; this
  decides only whose data a signed-in person sees.

  Every user has at least one membership and exactly one active (`memberships_one_active`). Each function
  here keeps that true in one transaction. The web layer closes the affected person's LiveViews after a
  change, since their scope comes from the active membership on each request.
  """

  import Ecto.Query

  alias Tore.{Repo, Scope}
  alias Tore.Accounts.{Membership, PendingMember, User}
  alias Tore.Household.HouseholdSchema

  @type add_result ::
          {:pending, String.t()} | {:moved, User.t()} | {:added, User.t()}

  @doc "The households a user belongs to, the active one marked, oldest first."
  @spec list_households(User.t()) :: [%{household: HouseholdSchema.t(), active: boolean()}]
  def list_households(%User{id: user_id}) do
    Repo.all(
      from m in Membership,
        join: h in assoc(m, :household),
        where: m.user_id == ^user_id,
        order_by: [m.inserted_at, m.household_id],
        select: %{household: h, active: m.active}
    )
  end

  @doc "People added to the scope's household who haven't signed in yet."
  @spec list_pending(Scope.t()) :: [PendingMember.t()]
  def list_pending(%Scope{household_id: household_id}) do
    Repo.all(
      from p in PendingMember, where: p.household_id == ^household_id, order_by: p.username
    )
  end

  @doc "Takes back an addition someone hasn't signed in for yet."
  @spec cancel_pending(Scope.t(), pos_integer()) :: :ok
  def cancel_pending(%Scope{household_id: household_id}, id) do
    Repo.delete_all(
      from p in PendingMember, where: p.id == ^id and p.household_id == ^household_id
    )

    :ok
  end

  @doc """
  Adds the person with this Pocket ID username to the scope's household. Someone who hasn't signed in yet
  joins at their first sign-in (`:pending`). Someone whose only household is empty, with nobody else in
  it, moves over and the empty one is deleted (`:moved`). Anyone else gets the household in their
  switcher (`:added`).
  """
  @spec add(Scope.t(), String.t()) ::
          {:ok, add_result()} | {:error, :username_missing | :already_member | :already_added}
  def add(%Scope{} = scope, username) do
    case String.trim(username) do
      "" -> {:error, :username_missing}
      username -> Repo.transaction(fn -> add_username(scope, username) end)
    end
  end

  @doc """
  Removes a member from the scope's household. Their other households are untouched; if this one was
  active, the oldest of the others becomes active, and someone left with none gets a new one. A sponsor
  who leaves stops sponsoring. The household's data stays with it, so its last member can't leave: that
  would leave the data with nobody able to reach it.
  """
  @spec remove(Scope.t(), pos_integer()) :: :ok | {:error, :not_member | :last_member}
  def remove(%Scope{household_id: household_id}, user_id) do
    Repo.transaction(fn ->
      case Repo.get_by(Membership, user_id: user_id, household_id: household_id) do
        nil ->
          Repo.rollback(:not_member)

        membership ->
          if member_count(household_id) == 1, do: Repo.rollback(:last_member)

          Repo.delete!(membership)

          Repo.update_all(
            from(h in HouseholdSchema,
              where: h.id == ^household_id and h.ai_sponsor_id == ^user_id
            ),
            set: [ai_sponsor_id: nil]
          )

          if membership.active, do: activate_another(Repo.get!(User, user_id))
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Makes `household_id` the user's active household."
  @spec switch(User.t(), pos_integer()) :: :ok | {:error, :not_member}
  def switch(%User{id: user_id}, household_id) do
    Repo.transaction(fn ->
      Repo.update_all(from(m in Membership, where: m.user_id == ^user_id), set: [active: false])

      # Checked here, not before: a membership removed meanwhile rolls the switch back.
      case Repo.update_all(
             from(m in Membership,
               where: m.user_id == ^user_id and m.household_id == ^household_id
             ),
             set: [active: true]
           ) do
        {1, _} -> :ok
        {0, _} -> Repo.rollback(:not_member)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "How many people belong to the household."
  @spec member_count(pos_integer()) :: non_neg_integer()
  def member_count(household_id) do
    Repo.aggregate(from(m in Membership, where: m.household_id == ^household_id), :count)
  end

  @doc """
  A household of the user's own, named after them and active, with its language left for /welcome.
  Someone with the credits claim sponsors it.
  """
  @spec start_own_household!(User.t()) :: HouseholdSchema.t()
  def start_own_household!(%User{} = user) do
    household =
      Repo.insert!(%HouseholdSchema{
        name: user.name,
        ai_sponsor_id: if(user.ai_enabled, do: user.id)
      })

    Repo.insert!(%Membership{user_id: user.id, household_id: household.id, active: true})
    household
  end

  @doc "Whether the household holds nothing: no members but `except_user_id`, no rows, nobody waiting to join."
  @spec empty?(pos_integer(), pos_integer()) :: boolean()
  def empty?(household_id, except_user_id) do
    not Repo.exists?(
      from(m in Membership,
        where: m.household_id == ^household_id and m.user_id != ^except_user_id
      )
    ) and
      not Repo.exists?(from(p in PendingMember, where: p.household_id == ^household_id)) and
      not Enum.any?(Repo.household_tables(), fn table ->
        Repo.exists?(from(row in table), household_id: household_id)
      end)
  end

  defp add_username(scope, username) do
    case Repo.get_by(User, username: username) do
      nil -> add_pending(scope, username)
      user -> add_user(scope, user)
    end
  end

  defp add_pending(scope, username) do
    %PendingMember{household_id: scope.household_id, added_by_id: scope.user_id}
    |> PendingMember.changeset(%{username: username})
    |> Repo.insert()
    |> case do
      {:ok, _} -> {:pending, username}
      {:error, _} -> Repo.rollback(:already_added)
    end
  end

  defp add_user(scope, user) do
    memberships = Repo.all(from m in Membership, where: m.user_id == ^user.id)

    cond do
      Enum.any?(memberships, &(&1.household_id == scope.household_id)) ->
        Repo.rollback(:already_member)

      match?([_], memberships) and empty?(hd(memberships).household_id, user.id) ->
        Repo.delete!(Repo.get!(HouseholdSchema, hd(memberships).household_id))

        Repo.insert!(%Membership{
          user_id: user.id,
          household_id: scope.household_id,
          active: true
        })

        # Like any new member, they start in the household's language, or get it once it's picked.
        user = start_in_language(user, Repo.get!(HouseholdSchema, scope.household_id).locale)
        {:moved, user}

      true ->
        Repo.insert!(%Membership{user_id: user.id, household_id: scope.household_id})
        {:added, user}
    end
  end

  defp start_in_language(user, nil), do: user

  defp start_in_language(user, locale),
    do: Repo.update!(Ecto.Changeset.change(user, locale: locale))

  defp activate_another(user) do
    case Repo.one(
           from m in Membership,
             where: m.user_id == ^user.id,
             order_by: [m.inserted_at, m.household_id],
             limit: 1
         ) do
      nil ->
        start_own_household!(user)

      next ->
        Repo.update_all(
          from(m in Membership,
            where: m.user_id == ^user.id and m.household_id == ^next.household_id
          ),
          set: [active: true]
        )
    end
  end
end
