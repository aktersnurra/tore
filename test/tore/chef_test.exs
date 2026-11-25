defmodule Tore.ChefTest do
  use Tore.DataCase, async: false

  alias Tore.{Chef, Pantry, Recipes}

  defp recipe do
    {:ok, recipe} = Recipes.create(home_scope(), %{title: "Pasta", recipe_type: :meal})
    recipe
  end

  # Cooked with a pantry row whose best-before is `days` from today (nil: none).
  defp cook(days) do
    {:ok, item} = Pantry.add_item(home_scope(), %{name: "grädde #{System.unique_integer()}"})

    if days do
      {:ok, _} =
        Pantry.set_expiry(home_scope(), item.id, Date.add(Tore.Clock.today(), days))
    end

    Chef.cooked(home_scope(), recipe().id, [%{id: item.id}])
  end

  test "a new household's chef starts at the sink, eight steps from Lärling" do
    assert %{dinners: 0, rescued: 0, steps: 0, stage: :dishwasher, extras: 0} =
             Chef.now(home_scope())

    assert Chef.now(home_scope()).next == %{stage: :apprentice, left: 8}
  end

  test "a dinner is a step; one that uses food at or past its date is two" do
    {:ok, _} = cook(nil)
    {:ok, _} = cook(10)
    {:ok, _} = cook(2)
    {:ok, _} = cook(-1)

    assert %{dinners: 4, rescued: 2, steps: 6} = Chef.now(home_scope())
  end

  test "undone, the dinner no longer counts" do
    {:ok, dinner} = cook(nil)
    :ok = Chef.uncooked(home_scope(), dinner)

    assert %{dinners: 0, steps: 0} = Chef.now(home_scope())
  end

  test "the ladder: a stage at 8, 25, 60 and 120 steps, then a thing in the kitchen per 40" do
    assert %{stage: :dishwasher, next: %{stage: :apprentice, left: 1}} = Chef.stage(7)
    assert %{stage: :apprentice, next: %{stage: :cook, left: 17}} = Chef.stage(8)
    assert %{stage: :cook} = Chef.stage(25)
    assert %{stage: :sous_chef, next: %{stage: :head_chef, left: 1}} = Chef.stage(119)
    assert %{stage: :head_chef, extras: 0, next: %{stage: :extra, left: 40}} = Chef.stage(120)
    assert %{stage: :head_chef, extras: 1, next: %{stage: :extra, left: 39}} = Chef.stage(161)
    assert %{stage: :head_chef, extras: 6, next: nil} = Chef.stage(1000)
  end

  describe "Today's scene" do
    defp scene(hour, day \\ %{}),
      do:
        Chef.today_scene(
          Map.merge(%{hour: hour, cooked: false, to_buy: false, dinner_tonight: false}, day)
        )

    test "asleep from 22 to 6, whatever the day" do
      assert scene(22, %{to_buy: true}) == :sleep
      assert scene(3) == :sleep
      assert scene(6) != :sleep
    end

    test "what's needed comes before the time: the list, then the stove at dinner time" do
      assert scene(8, %{to_buy: true, dinner_tonight: true}) == :list
      assert scene(17, %{to_buy: true, dinner_tonight: true}) == :list
      assert scene(17, %{dinner_tonight: true}) == :stove
      assert scene(14, %{dinner_tonight: true}) == :chef
    end

    test "coffee in the morning; content once dinner is cooked" do
      assert scene(7) == :morning
      assert scene(10) == :chef
      assert scene(18, %{cooked: true, dinner_tonight: true}) == :chef
    end
  end
end
