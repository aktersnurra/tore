defmodule Tore.Harness.InboxSweeperTest do
  use Tore.DataCase, async: false

  import Tore.RunFixtures

  alias Tore.Harness.InboxSweeper
  alias Tore.Storage.{Buckets, Mock}

  setup do
    Mock.reset()
    :ok
  end

  test "a sweep removes its household's finished photos and leaves the rest" do
    other = scope_fixture(household_fixture())
    {done, done_key} = run_with_photo_fixture(home_scope())
    {_open, open_key} = run_with_photo_fixture(home_scope())
    {theirs, their_key} = run_with_photo_fixture(other)
    fail_run(home_scope(), done)
    fail_run(other, theirs)

    :ok = InboxSweeper.sweep(home_scope().household_id)

    assert Mock.get(Buckets.runs(), done_key) == nil
    assert Mock.get(Buckets.runs(), open_key) == "photo bytes"
    assert Mock.get(Buckets.runs(), their_key) == "photo bytes"
  end
end
