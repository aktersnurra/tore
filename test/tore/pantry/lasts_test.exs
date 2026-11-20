defmodule Tore.Pantry.LastsTest do
  use Tore.DataCase, async: false

  alias Tore.{Costs, Pantry}
  alias Tore.Pantry.Lasts

  setup do
    for name <- ["Mjölk", "Spaghetti", "Smör"] do
      {:ok, _, _, _} =
        Pantry.upsert_belief(home_scope(), %{catalogue_name: name, provenance: "manual"})
    end

    :ok
  end

  defp req, do: Req.new(plug: {Req.Test, __MODULE__})

  # Jev, as a household would have it: milk goes in days, butter lasts weeks, pasta is for dinner.
  defp jev do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"questions" => questions} = Jason.decode!(body)
      send(test, {:asked, questions})

      answers =
        Map.new(questions, fn {key, %{"instructions" => text}} ->
          text = String.downcase(text)

          choice =
            cond do
              text =~ "mjölk" -> "days"
              text =~ "smör" -> "weeks"
              true -> "cooking"
            end

          {key, %{"choice" => choice, "confidence" => 0.8}}
        end)

      Req.Test.json(conn, %{"answers" => answers, "usage" => %{"cost" => 0.0001}})
    end)
  end

  defp half_lives,
    do: Map.new(Pantry.list_inventory(home_scope()), &{&1.name, &1.half_life_days})

  test "Jev says how each thing in the pantry is used, and that gives it its half-life" do
    jev()

    assert {:ok, 3} = Lasts.sort(home_scope(), req: req(), api_key: "k")
    assert_received {:asked, questions}

    assert Enum.all?(questions, fn {_key, q} ->
             q["type"] == "choice" and
               Map.keys(q["criteria"]) == ["cooking", "days", "week", "weeks"]
           end)

    assert half_lives() == %{"mjölk" => 3, "smör" => 21, "spaghetti" => nil}
    assert Costs.last_llm_call(home_scope(), "pantry_lasts")
  end

  test "each thing is asked about once" do
    jev()
    {:ok, 3} = Lasts.sort(home_scope(), req: req(), api_key: "k")
    assert_received {:asked, _}

    assert {:ok, 0} = Lasts.sort(home_scope(), req: req(), api_key: "k")
    refute_received {:asked, _}
  end

  test "the household's own rhythm beats Jev's guess" do
    jev()
    {:ok, 3} = Lasts.sort(home_scope(), req: req(), api_key: "k")
    :ok = Tore.Basics.ask(home_scope(), [%{name: "Mjölk"}])

    assert %{"mjölk" => 7} = half_lives()
  end

  test "a household without AI isn't asked about" do
    jev()
    unsponsored = scope_fixture(household_fixture())
    {:ok, _} = Pantry.add_item(unsponsored, %{name: "Mjölk"})

    assert {:error, :ai_unavailable} = Lasts.sort(unsponsored, req: req(), api_key: "k")
    refute_received {:asked, _}
  end
end
