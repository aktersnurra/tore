defmodule Tore.Household do
  import Ecto.Query, warn: false

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

  @spec locale_label(String.t()) :: String.t()
  def locale_label("en"), do: "English"
  def locale_label("sv"), do: "Svenska"
  def locale_label(code), do: code

  @doc "Every household's id, for jobs that run for each of them."
  @spec list_ids() :: [integer()]
  def list_ids, do: Repo.all(from h in HouseholdSchema, order_by: h.id, select: h.id)

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
