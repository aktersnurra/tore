defmodule Tore.Harness.ArtifactTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Artifact.Registry

  test "Registry.lookup/1 returns the module" do
    assert {:ok, Tore.Harness.Artifact.PlanDiff} = Registry.lookup("PlanDiff")
    assert {:ok, Tore.Harness.Artifact.CostEntry} = Registry.lookup("CostEntry")
    assert :error = Registry.lookup("Nonexistent")
  end
end
