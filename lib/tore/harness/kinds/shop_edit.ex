defmodule Tore.Harness.Kinds.ShopEdit do
  @moduledoc """
  Capture changes the shopping list as someone asked: adds an item, checks one off, or builds the
  week's list from the plan. The proposal is made before the run opens (`add/5`, `check/2`,
  `build/4`), so the run itself makes no LLM call.

  Undo is the inverse command: an added item is removed, a checked item unchecked. Building
  replaces the whole list, so it can't be undone. A checked-off item also goes into the pantry,
  through a pantry run of its own with its own undo.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.{Scope, Shop}
  alias Tore.Harness.Artifact.ShopChange
  alias Tore.Harness.{Kinds, Runs}
  alias Tore.Shop.Commands

  @doc "A new item for `list_id`, sorted into its shop section."
  @spec add(Scope.t(), String.t(), String.t(), Decimal.t() | nil, String.t() | nil) ::
          ShopChange.t()
  def add(%Scope{} = scope, list_id, name, quantity, unit) do
    item = %{
      id: Ecto.UUID.generate(),
      name: name,
      quantity: quantity,
      unit: unit,
      section: Shop.section_for(scope, name)
    }

    %ShopChange{list_id: list_id, change: :add, items: [ShopChange.item(item)]}
  end

  @doc "Checks off `item`, an item on `list_id` as the shop's state holds it."
  @spec check(String.t(), map()) :: ShopChange.t()
  def check(list_id, item),
    do: %ShopChange{list_id: list_id, change: :check, items: [ShopChange.item(item)]}

  @doc "The week's list from `recipe_ids`, without what the pantry holds."
  @spec build(Scope.t(), String.t(), Date.t(), [integer()]) :: ShopChange.t()
  def build(%Scope{} = scope, list_id, week_start, recipe_ids) do
    items = scope |> Shop.items_for(recipe_ids) |> Enum.map(&ShopChange.item/1)
    %ShopChange{list_id: list_id, change: :build, items: items, week_start: week_start}
  end

  @impl true
  def kind, do: "shop_edit_run"

  @impl true
  def surface, do: :shop

  @impl true
  def open(%{change: %ShopChange{list_id: list_id, change: change}}),
    do: %{input: %{"list_id" => list_id, "change" => Atom.to_string(change)}, actor: :user}

  @impl true
  def verify(%ShopChange{}, _ctx), do: :ok

  @impl true
  def review_question(_change), do: nil

  @impl true
  def apply_proposal(%ShopChange{list_id: list_id} = change, %{scope: scope}) do
    with {:ok, _events} <- Shop.append(scope, list_id, command(change, scope)),
         do: {:ok, undo(change), [change]}
  end

  @impl true
  def after_commit(%{status: :applied, artifacts: [%ShopChange{change: :check} = change]} = run) do
    scope = Scope.for_household(run.household_id)
    Shop.announce(scope)
    [item] = change.items

    Runs.start(scope, Kinds.PantryUpdate, %{
      channel: :grocery_checkoff,
      items: [%{name: item["name"], quantity: decimal(item["quantity"]), unit: item["unit"]}]
    })

    :ok
  end

  def after_commit(%{status: status} = run) when status in [:applied, :reverted],
    do: Shop.announce(Scope.for_household(run.household_id))

  def after_commit(_run), do: :ok

  defp command(%ShopChange{change: :add, items: [item]}, scope) do
    %Commands.AddItem{
      item_id: item["id"],
      name: item["name"],
      quantity: decimal(item["quantity"]),
      unit: item["unit"],
      section: item["section"],
      added_by: scope.user_id
    }
  end

  defp command(%ShopChange{change: :check, items: [item]}, scope),
    do: %Commands.CheckItem{item_id: item["id"], checked_by: scope.user_id}

  defp command(%ShopChange{change: :build} = change, _scope),
    do: %Commands.BuildList{week_start: change.week_start, items: change.items}

  defp undo(%ShopChange{change: :add, list_id: list_id, items: [item]}),
    do: {:steps, [{:remove_shop_item, list_id, item["id"]}]}

  defp undo(%ShopChange{change: :check, list_id: list_id, items: [item]}),
    do: {:steps, [{:uncheck_shop_item, list_id, item["id"]}]}

  defp undo(%ShopChange{change: :build}),
    do: {:irreversible, "Building the list replaced the one before it."}

  defp decimal(nil), do: nil
  defp decimal(s) when is_binary(s), do: Decimal.new(s)
end
