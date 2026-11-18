defmodule Tore.LLM.PiTest do
  use Tore.DataCase, async: false

  import Tore.FakePi

  alias Tore.{Costs, LLM}

  setup :fake_pi

  setup do
    Application.put_env(:tore, :llm_spec, Tore.LLM.Pi)
    on_exit(fn -> Application.put_env(:tore, :llm_spec, Tore.MockLLM) end)
  end

  defp prompt(log), do: Enum.find(pi_records(log), &(&1["type"] == "prompt"))

  @schema %{
    type: "json_schema",
    json_schema: %{name: "section", strict: true, schema: %{"type" => "object"}}
  }

  test "an answer is pi's JSON, asked as a one-shot, and its cost is the feature's", %{
    pi_log: log
  } do
    System.put_env("FAKE_PI_REPLY", ~s({"section": "dairy"}))
    System.put_env("FAKE_PI_COST", "0.02")

    assert {:ok, %{"section" => "dairy"}, %{cost_usd: 0.02}} =
             LLM.text(home_scope(), "Sort groceries.", "mjölk",
               response_format: @schema,
               feature: :learn
             )

    [header | _] = pi_records(log)
    assert header["oneshot"] == true
    assert header["session"] =~ ~r/^oneshot-\d+$/

    message = prompt(log)["message"]
    assert message =~ "Sort groceries.\n\nmjölk"
    assert message =~ ~s(JSON Schema:\n{"type":"object"})

    # Counted once, as what asked for it.
    assert [{"learn", 1, 0.02}] = Costs.llm_calls_this_month_by_feature(home_scope())
    assert DynamicSupervisor.which_children(Tore.Pi.Sessions) == []
  end

  test "the one-shot model answers one-shots when there is one", %{pi_log: log} do
    Application.put_env(
      :tore,
      :pi,
      Keyword.put(Application.get_env(:tore, :pi), :oneshot_model, "anthropic/claude-haiku-5-5")
    )

    System.put_env("FAKE_PI_REPLY", "{}")
    assert {:ok, %{}, _} = LLM.text(home_scope(), "sys", "user")

    assert [%{"model" => "anthropic/claude-haiku-5-5"} | _] = pi_records(log)
  end

  test "a reply in a Markdown fence is read, and one that isn't JSON is an error" do
    System.put_env("FAKE_PI_REPLY", "```json\n{\"ok\": true}\n```")
    assert {:ok, %{"ok" => true}, _} = LLM.text(home_scope(), "sys", "user")

    System.put_env("FAKE_PI_REPLY", "Here you go!")
    assert {:error, :invalid_json} = LLM.text(home_scope(), "sys", "user")
  end

  test "photos go as images, each with its type", %{pi_log: log} do
    System.put_env("FAKE_PI_REPLY", ~s({"total": 120}))
    png = <<0x89, "PNG", 1, 2>>
    jpeg = <<255, 216, 255, 0>>

    assert {:ok, %{"total" => 120}, _} =
             LLM.vision(home_scope(), [{:image, png}, {:image, jpeg}], "Read it.", "receipt")

    assert [%{"mimeType" => "image/png"}, %{"mimeType" => "image/jpeg", "data" => data}] =
             prompt(log)["images"]

    assert Base.decode64!(data) == jpeg
  end

  test "a decision is asked with the facts and questions, and answered per question", %{
    pi_log: log
  } do
    System.put_env(
      "FAKE_PI_REPLY",
      ~s({"screen": {"choice": "plan", "confidence": 0.9}, "swap_open_shop": {"noul": 0.7}})
    )

    questions = %{"screen" => %{"type" => "choice", "criteria" => %{"plan" => "Plan it."}}}

    assert {:ok, %{"screen" => %{"choice" => "plan"}, "swap_open_shop" => %{"noul" => 0.7}}, _} =
             LLM.decide(home_scope(), ["It is Monday."], questions, feature: :home_pick)

    message = prompt(log)["message"]
    assert message =~ "It is Monday."
    assert message =~ Jason.encode!(questions)
  end

  test "a pi that can't answer is an error, and nothing is counted" do
    Application.put_env(:tore, :pi, command: ["false"])

    assert {:error, _} = LLM.text(home_scope(), "sys", "user", feature: :learn)
    assert Costs.llm_calls_this_month_by_feature(home_scope()) == []
  end
end
