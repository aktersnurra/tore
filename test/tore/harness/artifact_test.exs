defmodule Tore.Harness.ArtifactTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Artifact
  alias Tore.Harness.Artifact.Registry

  defmodule Dummy do
    @behaviour Tore.Harness.Artifact
    defstruct [:rationale, :n]
    @impl true
    def kind, do: "Dummy"
    @impl true
    def to_json(%__MODULE__{n: n}), do: %{"n" => n}
    @impl true
    def from_json(%{"n" => n}), do: %__MODULE__{n: n}
    @impl true
    def summary(%__MODULE__{n: n}),
      do: %{counts: %{items: n}, text_fallback: "n=#{n}"}

    @impl true
    def is_rationale_complete(%__MODULE__{rationale: r}), do: r in [nil, []] == false
  end

  test "Artifact.is_rationale_complete/1 dispatches to module callback" do
    refute Artifact.is_rationale_complete(%Dummy{rationale: nil, n: 0})
    assert Artifact.is_rationale_complete(%Dummy{rationale: ["why"], n: 0})
  end

  test "Artifact.summary/1 dispatches to module callback" do
    assert %{counts: %{items: 3}, text_fallback: "n=3"} =
             Artifact.summary(%Dummy{rationale: ["x"], n: 3})
  end

  test "Registry.kinds/0 lists registered kinds" do
    assert "PlanDiff" in Registry.kinds()
    assert "RecipeProposal" in Registry.kinds()
  end

  test "Registry.lookup/1 returns the module" do
    assert {:ok, Tore.Harness.Artifact.PlanDiff} = Registry.lookup("PlanDiff")
    assert {:ok, Tore.Harness.Artifact.CostEntry} = Registry.lookup("CostEntry")
    assert :error = Registry.lookup("Nonexistent")
  end

  test "Registry.modules/0 returns module list" do
    assert Tore.Harness.Artifact.PlanDiff in Registry.modules()
  end
end
