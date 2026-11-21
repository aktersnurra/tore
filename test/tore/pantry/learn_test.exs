defmodule Tore.Pantry.LearnTest do
  @moduledoc "New names, learned by Jev afterwards, and pi's list_ingredients and learn_ingredients."
  use Tore.DataCase, async: false

  alias Tore.{Mcp, Pantry}
  alias Tore.Pantry.{Learn, Match}
  alias Tore.Recipes.Ingredient

  defp ingredient(scope, attrs) do
    %Ingredient{household_id: scope.household_id}
    |> Ingredient.changeset(attrs)
    |> Repo.insert!()
  end

  defp tick(scope, name) do
    Tore.Harness.Runs.start(scope, Tore.Harness.Kinds.PantryUpdate, %{
      channel: :grocery_checkoff,
      items: [%{name: name, quantity: 1, unit: "l"}]
    })
  end

  defp tool(name, args) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

    {:reply, %{"result" => %{"isError" => false, "structuredContent" => content}}} =
      Mcp.handle(home_scope(), request)

    content |> Jason.encode!() |> Jason.decode!()
  end

  defp learned(items), do: tool("learn_ingredients", %{"items" => items})

  test "list_ingredients names the household's ingredients, with their sections" do
    ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})
    ingredient(home_scope(), %{name: "Gräddfil"})

    assert tool("list_ingredients", %{}) == %{
             "ingredients" => [
               %{"name" => "Gräddfil", "section" => nil, "price_guess" => nil},
               %{"name" => "Mjölk", "section" => "dairy", "price_guess" => nil}
             ]
           }
  end

  test "a new name pi says is an ingredient Tore has is merged into it, once" do
    scope = home_scope()
    milk = ingredient(scope, %{name: "Mjölk", category: "dairy"})
    {:ok, _} = tick(scope, "Mellanmjölk")

    assert %{"merged" => 1} =
             learned([%{"name" => "Mellanmjölk", "same_as" => "Mjölk", "section" => "dairy"}])

    assert [%{ingredient_id: id, name: "mjölk"}] = Pantry.list_inventory(scope)
    assert id == milk.id
    assert {:ok, %Ingredient{id: ^id}} = Match.ingredient(scope, {:name, "Mellanmjölk"})
    refute Repo.get_by(Ingredient, [key: "mellanmjolk"], Tore.Scope.repo_opts(scope))
  end

  test "merging keeps the row already there when both had one" do
    scope = home_scope()
    milk = ingredient(scope, %{name: "Mjölk", category: "dairy"})
    {:ok, _} = tick(scope, "Mjölk")
    {:ok, _} = tick(scope, "Mellanmjölk")

    learned([%{"name" => "Mellanmjölk", "same_as" => "Mjölk", "section" => "dairy"}])

    assert [%{ingredient_id: id}] = Pantry.list_inventory(scope)
    assert id == milk.id
  end

  test "a name that is its own ingredient gets its section and shelf life" do
    scope = home_scope()
    {:ok, _} = tick(scope, "Gräddfil")

    assert %{"learned" => 1} =
             learned([
               %{
                 "name" => "Gräddfil",
                 "same_as" => nil,
                 "section" => "dairy",
                 "shelf_life_days" => 14
               }
             ])

    assert {:ok, %Ingredient{category: "dairy", shelf_life_days: 14}} =
             Match.ingredient(scope, {:name, "Gräddfil"})
  end

  test "a name or a same_as Tore doesn't have is reported, and changes nothing" do
    ingredient(home_scope(), %{name: "Gräddfil"})

    assert %{"unknown_names" => ["Kvarg"], "unknown_same_as" => ["Gräddfil"]} =
             learned([
               %{"name" => "Kvarg", "same_as" => nil, "section" => "dairy"},
               %{"name" => "Gräddfil", "same_as" => "Filmjölk", "section" => "dairy"}
             ])

    assert {:ok, %Ingredient{category: nil}} =
             Match.ingredient(home_scope(), {:name, "Gräddfil"})
  end

  describe "names/3" do
    defp req, do: Req.new(plug: {Req.Test, __MODULE__})

    # Jev, as a household would have it: gräddfil is dairy and keeps a week; mellanmjölk is
    # mjölk, as sure as `same` says.
    defp jev(same \\ 0.95) do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"questions" => questions, "state" => state} = Jason.decode!(body)
        send(test, {:asked, questions, state})

        answers =
          Map.new(questions, fn
            {"same_" <> _ = key, %{"criteria" => criteria}} ->
              choice = if Map.has_key?(criteria, "Mjölk"), do: "Mjölk", else: "own"
              {key, %{"choice" => choice, "confidence" => same}}

            {"section_" <> _ = key, _} ->
              {key, %{"choice" => "dairy", "confidence" => 0.9}}

            {"keeps_" <> _ = key, _} ->
              {key, %{"choice" => "week", "confidence" => 0.8}}
          end)

        Req.Test.json(conn, %{"answers" => answers, "usage" => %{"cost" => 0.0001}})
      end)
    end

    defp learn(names), do: Learn.names(home_scope(), names, req: req(), api_key: "k")

    test "Jev says what a new name is: its section and how long it keeps" do
      jev()
      ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})

      assert :ok = learn(["Mjölk", "Gräddfil"])
      assert_received {:asked, questions, state}
      assert Enum.any?(state, &(&1 =~ "Swedish"))
      # Only Gräddfil, which has nothing it could be a kind of: what it is and how long it keeps.
      assert Enum.sort(Enum.map(questions, fn {key, _} -> hd(String.split(key, "_")) end)) ==
               ["keeps", "section"]

      assert {:ok, %Ingredient{category: "dairy", shelf_life_days: 7}} =
               Match.ingredient(home_scope(), {:name, "Gräddfil"})

      assert Tore.Costs.last_llm_call(home_scope(), "learn")
    end

    test "a kind of one the household has is merged into it when Jev is sure" do
      jev()
      %{id: milk} = ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})
      ingredient(home_scope(), %{name: "Smör", category: "dairy"})

      assert :ok = learn(["Mellanmjölk"])

      # Jev picks only among names one inside the other.
      assert_received {:asked, questions, _state}
      {_key, %{"criteria" => criteria}} = Enum.find(questions, fn {k, _} -> k =~ "same_" end)
      assert Map.keys(criteria) |> Enum.sort() == ["Mjölk", "own"]

      assert {:ok, %Ingredient{id: ^milk}} =
               Match.ingredient(home_scope(), {:name, "Mellanmjölk"})
    end

    test "unsure, it stays its own, with its own section" do
      jev(0.6)
      %{id: milk} = ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})

      assert :ok = learn(["Mellanmjölk"])

      assert {:ok, %Ingredient{id: id, category: "dairy"}} =
               Match.ingredient(home_scope(), {:name, "Mellanmjölk"})

      assert id != milk
    end

    test "nothing to compare it with, it's only asked what it is" do
      jev()
      assert :ok = learn(["Gräddfil"])
      assert_received {:asked, questions, _state}
      refute Enum.any?(questions, fn {key, _} -> key =~ "same_" end)
    end

    test "asks nothing when every name is learned" do
      jev()
      ingredient(home_scope(), %{name: "Mjölk", category: "dairy"})

      assert :ok = learn(["Mjölk"])
      refute_received {:asked, _, _}
    end
  end

  test "without AI, a new name stays as written" do
    scope = scope_fixture(household_fixture())
    {:ok, _} = tick(scope, "Gräddfil")

    assert :ok = Learn.names(scope, ["Gräddfil"])
    assert {:ok, %Ingredient{category: nil}} = Match.ingredient(scope, {:name, "Gräddfil"})
  end
end
