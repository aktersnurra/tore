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

  @provenances ~w[manual receipt vision belief grocery_checkoff barcode]
  @beliefs ~w[confirmed probable uncertain missing]
  @expires_sources ~w[label estimate manual]

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
    # Its basic's rhythm, when it's eaten between dinners; loaded with the row, never stored here.
    field :half_life_days, :integer, virtual: true
    belongs_to :ingredient, Tore.Recipes.Ingredient
    timestamps()
  end

  def categories, do: @categories

  def category_values, do: Enum.map(@categories, &Atom.to_string/1)

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

  @doc """
  How sure Tore is that the item is still there: the stored belief, as of `now`, with its date
  judged against `today` (`Tore.Clock.today/0`). Pure: the stored row keeps the strongest
  observation; this is read at render time.

  What's only cooked with (pasta, spices, the salmon for Friday) changes when a dinner or the
  household says so, never by itself. Something eaten between dinners (a basic: milk, bread) has
  a half-life, its rhythm (`half_life_days`): the chance it's still there halves every rhythm
  since it was last seen. At a half or less it's unsure, at a quarter or less it's gone. Past its
  date anything is unsure. Stored `uncertain` and `missing` stay as they are.
  """
  @spec effective_belief(%__MODULE__{}, DateTime.t(), Date.t()) ::
          :confirmed | :probable | :uncertain | :missing
  def effective_belief(%__MODULE__{belief: "missing"}, _now, _today), do: :missing
  def effective_belief(%__MODULE__{belief: "uncertain"}, _now, _today), do: :uncertain

  def effective_belief(%__MODULE__{belief: belief} = item, %DateTime{} = now, %Date{} = today) do
    stored = String.to_existing_atom(belief || "uncertain")

    cond do
      past_date?(item, today) -> :uncertain
      still_there(item, now) <= 0.25 -> :missing
      still_there(item, now) <= 0.5 -> :uncertain
      true -> stored
    end
  end

  @doc "The chance the item is still there, by its half-life; 1.0 for what doesn't have one."
  @spec still_there(%__MODULE__{}, DateTime.t()) :: float()
  def still_there(%__MODULE__{half_life_days: days, last_seen_at: %DateTime{} = seen}, now)
      when is_integer(days) and days > 0,
      do: :math.pow(0.5, DateTime.diff(now, seen, :second) / (days * 86_400))

  def still_there(%__MODULE__{}, _now), do: 1.0

  @spec past_date?(%__MODULE__{}, Date.t()) :: boolean()
  def past_date?(%__MODULE__{expires_at: %Date{} = expires_at}, %Date{} = today),
    do: Date.after?(today, expires_at)

  def past_date?(%__MODULE__{}, %Date{}), do: false

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
