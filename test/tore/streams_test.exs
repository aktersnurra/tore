defmodule Tore.StreamsTest do
  use ExUnit.Case, async: true

  alias Tore.{Scope, Streams}

  @scope Scope.for_household(42)

  test "a plan id names the household and the Monday of the week" do
    assert Streams.plan(@scope, ~D[2026-11-04]) == "plan:42:2026-11-02"
    assert Streams.plan(@scope, ~D[2026-11-02]) == "plan:42:2026-11-02"
    assert Streams.plan(@scope, ~D[2026-11-08]) == "plan:42:2026-11-02"
  end

  test "a shopping list id does the same" do
    assert Streams.shop_list(@scope, ~D[2026-11-04]) == "shop_list:42:2026-11-02"
  end

  test "the same week gives different ids in different households" do
    refute Streams.plan(@scope, ~D[2026-11-02]) ==
             Streams.plan(Scope.for_household(43), ~D[2026-11-02])
  end

  test "week_start reads the Monday back" do
    assert Streams.week_start("plan:42:2026-11-02") == ~D[2026-11-02]
  end
end
