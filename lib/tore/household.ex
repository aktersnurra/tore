defmodule Tore.Household do
  import Ecto.Query, warn: false
  require Logger

  alias Tore.Accounts.{Membership, User}

  alias Tore.{
    Repo,
    Scope,
    Household.HouseholdSchema,
    Household.HouseholdInsight,
    Household.Preferences
  }

  @spec get!(Scope.t()) :: HouseholdSchema.t()
  def get!(%Scope{household_id: id}), do: Repo.get!(HouseholdSchema, id)

  @doc "The language everything the household stores is written in."
  @spec locale(Scope.t()) :: String.t() | nil
  def locale(%Scope{} = scope), do: get!(scope).locale

  @spec rename(Scope.t(), String.t()) :: {:ok, HouseholdSchema.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Scope{} = scope, name) do
    scope |> get!() |> HouseholdSchema.changeset(%{name: String.trim(name)}) |> Repo.update()
  end

  @doc """
  The member whose AI credits the household spends, or nil. Only someone still in the household and still
  holding the credits claim counts, so a sponsor who leaves or loses the claim stops on their own.
  """
  @spec ai_sponsor(Scope.t()) :: User.t() | nil
  def ai_sponsor(%Scope{household_id: household_id}) do
    Repo.one(
      from h in HouseholdSchema,
        join: u in User,
        on: u.id == h.ai_sponsor_id and u.ai_enabled,
        join: m in Membership,
        on: m.user_id == u.id and m.household_id == h.id,
        where: h.id == ^household_id,
        select: u
    )
  end

  @doc """
  Lets the household spend `user`'s AI credits, or stops it. Only the person themselves, with the
  credits claim, can turn it on; being added to a household never does.
  """
  @spec set_ai_sponsor(Scope.t(), User.t(), boolean()) ::
          {:ok, HouseholdSchema.t()} | {:error, :not_allowed}
  def set_ai_sponsor(%Scope{user_id: user_id} = scope, %User{id: user_id} = user, true)
      when user.ai_enabled do
    {:ok, scope |> get!() |> Ecto.Changeset.change(ai_sponsor_id: user_id) |> Repo.update!()}
  end

  def set_ai_sponsor(%Scope{user_id: user_id} = scope, %User{id: user_id}, false) do
    household = get!(scope)

    if household.ai_sponsor_id == user_id,
      do: {:ok, household |> Ecto.Changeset.change(ai_sponsor_id: nil) |> Repo.update!()},
      else: {:ok, household}
  end

  def set_ai_sponsor(%Scope{}, %User{}, _on), do: {:error, :not_allowed}

  @doc """
  Sets the household's language, and its members' with it, since each starts in the household's
  language. Only once: a household that has one keeps it, even when two members pick at the same moment.
  """
  @spec set_locale(Scope.t(), String.t()) ::
          {:ok, HouseholdSchema.t()} | {:error, :already_set | :invalid_locale}
  def set_locale(%Scope{household_id: household_id} = scope, locale) when locale in ~w(sv en) do
    Repo.transaction(fn ->
      case Repo.update_all(
             from(h in HouseholdSchema, where: h.id == ^household_id and is_nil(h.locale)),
             set: [locale: locale]
           ) do
        {1, _} ->
          Repo.update_all(
            from(u in User,
              where:
                u.id in subquery(
                  from m in Membership, where: m.household_id == ^household_id, select: m.user_id
                )
            ),
            set: [locale: locale]
          )

          get!(scope)

        {0, _} ->
          Repo.rollback(:already_set)
      end
    end)
  end

  def set_locale(%Scope{}, _locale), do: {:error, :invalid_locale}

  @spec locale_label(String.t()) :: String.t()
  def locale_label("en"), do: "English"
  def locale_label("sv"), do: "Svenska"
  def locale_label(code), do: code

  @doc "Every household's id, for jobs that run for each of them."
  @spec list_ids() :: [integer()]
  def list_ids, do: Repo.all(from h in HouseholdSchema, order_by: h.id, select: h.id)

  @doc """
  Runs `fun` with each household's scope, for jobs that run for every household. A household whose
  run raises or exits is logged, and the rest still run.
  """
  @spec each_scope((Scope.t() -> term())) :: :ok
  def each_scope(fun) do
    Enum.each(list_ids(), fn id ->
      try do
        fun.(Scope.for_household(id))
      catch
        kind, reason ->
          Logger.error(
            "job failed for household #{id}: " <> Exception.format(kind, reason, __STACKTRACE__)
          )
      end
    end)
  end

  @spec create_household(map()) :: {:ok, HouseholdSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_household(attrs) do
    %HouseholdSchema{}
    |> HouseholdSchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_preferences(Scope.t()) :: Preferences.t()
  def get_preferences(%Scope{} = scope) do
    Repo.one(Preferences, Scope.repo_opts(scope)) ||
      %Preferences{household_id: scope.household_id}
  end

  @spec update_preferences(Scope.t(), map()) ::
          {:ok, Preferences.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(%Scope{} = scope, attrs) do
    scope
    |> get_preferences()
    |> Preferences.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec prefs_to_dietary_guidance(Preferences.t()) :: String.t() | nil
  def prefs_to_dietary_guidance(%Preferences{} = p) do
    parts =
      [
        restrictions_line(p.dietary_restrictions),
        allergies_line(p.allergies),
        dislikes_line(p.dislikes),
        style_line(p.cooking_style),
        cuisine_line(p.cuisine_preferences)
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, "; ")
  end

  defp restrictions_line(nil), do: nil
  defp restrictions_line([]), do: nil
  defp restrictions_line(list), do: "Diet: #{Enum.join(list, ", ")}"

  defp allergies_line(nil), do: nil
  defp allergies_line([]), do: nil
  defp allergies_line(list), do: "Allergies/hard avoids: #{Enum.join(list, ", ")}"

  defp dislikes_line(nil), do: nil
  defp dislikes_line([]), do: nil
  defp dislikes_line(list), do: "Avoid too often: #{Enum.join(list, ", ")}"

  defp style_line(nil), do: nil
  defp style_line([]), do: nil
  defp style_line(list), do: "Cooking style: #{Enum.join(list, ", ")}"

  defp cuisine_line(nil), do: nil
  defp cuisine_line(map) when map == %{}, do: nil

  defp cuisine_line(map) do
    more = map |> Enum.filter(fn {_, v} -> v == "more" end) |> Enum.map(&elem(&1, 0))
    less = map |> Enum.filter(fn {_, v} -> v == "less" end) |> Enum.map(&elem(&1, 0))

    [
      if(more != [], do: "More of: #{Enum.join(more, ", ")}"),
      if(less != [], do: "Less of: #{Enum.join(less, ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> "Cuisine: #{Enum.join(parts, "; ")}"
    end
  end

  @spec list_active_insights(Scope.t()) :: [HouseholdInsight.t()]
  def list_active_insights(%Scope{} = scope) do
    from(i in HouseholdInsight,
      where: i.status == "active",
      order_by: [desc: i.confidence]
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  @spec dismiss_insight(Scope.t(), integer()) ::
          {:ok, HouseholdInsight.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_insight(%Scope{} = scope, id) do
    Repo.get!(HouseholdInsight, id, Scope.repo_opts(scope))
    |> HouseholdInsight.changeset(%{status: "dismissed"})
    |> Repo.update()
  end

  @spec replace_insights(Scope.t(), [map()]) :: {:ok, [HouseholdInsight.t()]} | {:error, term()}
  def replace_insights(%Scope{} = scope, new_insights) when is_list(new_insights) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      from(i in HouseholdInsight, where: i.status == "active")
      |> Repo.update_all([set: [status: "superseded"]], Scope.repo_opts(scope))

      Enum.map(new_insights, fn attrs ->
        %HouseholdInsight{household_id: scope.household_id}
        |> HouseholdInsight.changeset(%{
          kind: attrs.kind || attrs["kind"],
          body: attrs.body || attrs["body"],
          confidence: attrs.confidence || attrs["confidence"] || 0.5,
          evidence: encode_evidence(attrs[:evidence] || attrs["evidence"]),
          status: "active",
          generated_at: now
        })
        |> Repo.insert!()
      end)
    end)
  end

  defp encode_evidence(nil), do: nil
  defp encode_evidence(ids) when is_list(ids), do: Jason.encode!(ids)
end
