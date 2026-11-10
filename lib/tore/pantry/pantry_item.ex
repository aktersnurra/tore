defmodule Tore.Pantry.PantryItem do
  use Ecto.Schema
  import Ecto.Changeset

  @categories [
    :dairy,
    :meat,
    :produce,
    :frozen,
    :dry_goods,
    :canned,
    :herbs_spices,
    :condiments,
    :other
  ]

  @provenances ~w[manual receipt vision belief grocery_checkoff]
  @beliefs ~w[confirmed probable uncertain missing]
  @expires_sources ~w[label estimate manual]

  def categories, do: @categories

  def category_values, do: Enum.map(@categories, &Atom.to_string/1)

  def provenances, do: @provenances

  def beliefs, do: @beliefs

  @doc """
  Maps a provenance value to the belief we'd assign by default. Receipt and
  grocery-checkoff items are downgraded to `probable` because they tell us
  what was bought, not whether it's still in the cupboard.
  """
  def derive_belief("manual"), do: "confirmed"
  def derive_belief("vision"), do: "confirmed"
  def derive_belief("receipt"), do: "probable"
  def derive_belief("grocery_checkoff"), do: "probable"
  def derive_belief("belief"), do: "uncertain"
  def derive_belief(_), do: "confirmed"

  # Belief decays with recency: the longer since we last observed the
  # item, the less confident we are it's still there. An expiry date replaces
  # the fixed schedule, so fresh fish and salt don't lose belief alike. Pure
  # read-side projection — the stored row keeps the strongest observation; the
  # UI asks for the *effective* belief at render time.
  @confirmed_max_age_days 14
  @probable_max_age_days 30

  @doc """
  Decay the stored belief by `last_seen_at`, as of `now`, and judge its date against `today`,
  the household's date (`Tore.Clock.today/0`). Returns the belief atom the
  UI should render. Stored `:uncertain` / `:missing` are returned as-is;
  rows with no `last_seen_at` (manual adds that bypassed the receipt
  path) keep their stored belief.
  """
  @spec effective_belief(%__MODULE__{}, DateTime.t(), Date.t()) ::
          :confirmed | :probable | :uncertain | :missing
  def effective_belief(%__MODULE__{belief: "missing"}, _now, _today), do: :missing
  def effective_belief(%__MODULE__{belief: "uncertain"}, _now, _today), do: :uncertain

  def effective_belief(
        %__MODULE__{expires_at: %Date{}} = item,
        %DateTime{} = now,
        %Date{} = today
      ) do
    cond do
      past_date?(item, today) -> :uncertain
      item.belief == "confirmed" and age_days(item, now) <= @confirmed_max_age_days -> :confirmed
      true -> :probable
    end
  end

  def effective_belief(%__MODULE__{belief: belief, last_seen_at: nil}, _now, _today),
    do: String.to_existing_atom(belief || "uncertain")

  def effective_belief(
        %__MODULE__{belief: belief, last_seen_at: %DateTime{} = seen},
        %DateTime{} = now,
        _today
      ) do
    age_days = DateTime.diff(now, seen, :day)
    decay(belief, age_days)
  end

  @spec past_date?(%__MODULE__{}, Date.t()) :: boolean()
  def past_date?(%__MODULE__{expires_at: %Date{} = expires_at}, %Date{} = today),
    do: Date.after?(today, expires_at)

  def past_date?(%__MODULE__{}, %Date{}), do: false

  defp age_days(%__MODULE__{last_seen_at: nil}, _now), do: 0
  defp age_days(%__MODULE__{last_seen_at: seen}, now), do: DateTime.diff(now, seen, :day)

  defp decay("confirmed", age) when age > @probable_max_age_days, do: :uncertain
  defp decay("confirmed", age) when age > @confirmed_max_age_days, do: :probable
  defp decay("confirmed", _), do: :confirmed
  defp decay("probable", age) when age > @probable_max_age_days, do: :uncertain
  defp decay("probable", _), do: :probable
  defp decay("uncertain", _), do: :uncertain
  defp decay("missing", _), do: :missing
  defp decay(_, _), do: :uncertain

  schema "pantry_items" do
    field :name, :string
    field :quantity, :decimal
    field :unit, :string
    field :category, :string
    field :added_at, :date
    field :expires_at, :date
    field :expires_source, :string
    field :provenance, :string, default: "manual"
    field :belief, :string, default: "confirmed"
    field :last_seen_at, :utc_datetime
    field :household_id, :integer
    belongs_to :ingredient, Tore.Recipes.Ingredient
    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :name,
      :quantity,
      :unit,
      :category,
      :ingredient_id,
      :added_at,
      :expires_at,
      :expires_source,
      :provenance,
      :belief,
      :last_seen_at
    ])
    |> validate_required([:name, :added_at, :provenance])
    |> update_change(:name, &normalize_name/1)
    |> validate_inclusion(:category, category_values())
    |> validate_inclusion(:provenance, @provenances)
    |> validate_inclusion(:belief, @beliefs)
    |> validate_inclusion(:expires_source, @expires_sources)
  end

  defp normalize_name(name), do: name |> String.trim() |> String.downcase()
end
