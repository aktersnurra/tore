defmodule Tore.Pantry.Scan do
  @moduledoc """
  A pack scanned while unpacking goes into the pantry. A barcode Tore has seen is instant; a new
  one is looked up once in Open Food Facts and learned, with its pack and its photo. A pack that's still on the
  shopping list unticked was just bought, so it's ticked instead, which puts it in the pantry as
  a tick always does.

  A code nobody knows comes back as `:unknown_product`, and the scanner asks for a name once
  (`name:`); the code is learned under it.
  """

  alias Tore.{Scope, Shop}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds.PantryUpdate
  alias Tore.Pantry.{Learn, Match, OpenFoodFacts}
  alias Tore.Recipes.Ingredient

  @type result ::
          {:ok, %{name: String.t(), change: :added, run_id: String.t()}}
          | {:ok, %{name: String.t(), change: :ticked, item_id: String.t()}}
          | {:error, :not_a_barcode | :unknown_product | {:lookup_failed, term()} | term()}

  @spec scan(Scope.t(), String.t(), String.t(), keyword()) :: result()
  def scan(%Scope{} = scope, list_id, code, opts) do
    with :ok <- barcode?(code),
         {:ok, ingredient, pack} <- known(scope, code, opts[:name]) do
      place(scope, list_id, ingredient, pack, opts[:user_id])
    end
  end

  # EAN-8, UPC-A and EAN-13: what's printed on groceries.
  defp barcode?(code) do
    if Regex.match?(~r/^(\d{8}|\d{12}|\d{13})$/, code), do: :ok, else: {:error, :not_a_barcode}
  end

  defp known(scope, code, name) do
    case Match.barcode(scope, code) do
      {:ok, ingredient, pack} -> {:ok, ingredient, pack}
      :unknown -> learn(scope, code, name)
    end
  end

  # A name someone typed says what they mean: an ingredient Tore knows needs no model.
  defp learn(scope, code, name) when is_binary(name) and name != "" do
    ingredient =
      case Match.ingredient(scope, {:name, name}) do
        {:ok, ingredient} -> ingredient
        :unknown -> Learn.product(scope, name)
      end

    :ok = Match.learn_alias(scope, {:barcode, code}, ingredient.id)
    {:ok, ingredient, %{quantity: nil, unit: nil}}
  end

  defp learn(scope, code, _name) do
    case OpenFoodFacts.product(code) do
      {:ok, product} ->
        ingredient = Learn.product(scope, product.name)
        pack = Map.take(product, [:quantity, :unit])
        :ok = Match.learn_alias(scope, {:barcode, code}, ingredient.id, pack)
        if product.image_url, do: Tore.Pantry.keep_picture(scope, ingredient, product.image_url)
        {:ok, ingredient, pack}

      :unknown ->
        {:error, :unknown_product}

      {:error, reason} ->
        {:error, {:lookup_failed, reason}}
    end
  end

  defp place(scope, list_id, %Ingredient{} = ingredient, pack, user_id) do
    case waiting_item(scope, list_id, ingredient) do
      nil ->
        item = %{name: ingredient.name, quantity: pack.quantity, unit: pack.unit}

        case Runs.start(scope, PantryUpdate, %{channel: :barcode, items: [item]}) do
          {:ok, %KitchenRun{status: :applied, id: id}} ->
            {:ok, %{name: ingredient.name, change: :added, run_id: id}}

          {:ok, %KitchenRun{failure_code: code}} ->
            {:error, code}

          {:error, _} = error ->
            error
        end

      item ->
        with {:ok, _} <- Shop.check_item(scope, list_id, item.id, user_id),
             do: {:ok, %{name: item.name, change: :ticked, item_id: item.id}}
    end
  end

  defp waiting_item(scope, list_id, ingredient) do
    {:ok, state} = Shop.load_list(scope, list_id)

    state.items
    |> Map.values()
    |> Enum.reject(& &1.checked)
    |> Enum.find(fn item ->
      match?(
        {:ok, %Ingredient{id: id}} when id == ingredient.id,
        Match.ingredient(scope, {:name, item.name})
      )
    end)
  end
end
