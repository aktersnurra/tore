defmodule Tore.Recipes.Pictures.MakerTest do
  use ExUnit.Case, async: false

  alias Tore.Recipes.Pictures.Maker

  test "the same job asked for at once runs once, and everyone gets its result" do
    test = self()

    fun = fn ->
      send(test, :ran)
      Process.sleep(100)
      :made
    end

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> Maker.run({:dedup, test}, fun, 5_000) end) end)
      |> Task.await_many()

    assert results == List.duplicate(:made, 5)
    assert_received :ran
    refute_received :ran
  end

  test "no more than the concurrency run at a time" do
    {:ok, counter} = Agent.start_link(fn -> {0, 0} end)

    fun = fn ->
      Agent.update(counter, fn {now, top} -> {now + 1, max(top, now + 1)} end)
      Process.sleep(50)
      Agent.update(counter, fn {now, top} -> {now - 1, top} end)
      :ok
    end

    1..6
    |> Enum.map(fn i -> Task.async(fn -> Maker.run({:limit, i}, fun, 5_000) end) end)
    |> Task.await_many()

    assert {0, top} = Agent.get(counter, & &1)
    assert top == Application.get_env(:tore, :image_resize_concurrency, 2)
  end

  test "a caller that can't wait gets a timeout, and the work still finishes for others" do
    fun = fn ->
      Process.sleep(200)
      :late
    end

    waiter = Task.async(fn -> Maker.run({:slow, self()}, fun, 5_000) end)
    Process.sleep(10)
    assert {:error, :timeout} = Maker.run({:slow, waiter.pid}, fun, 20)
    assert Task.await(waiter) == :late
  end

  @tag :capture_log
  test "a job that crashes is an error, and the queue goes on" do
    assert {:error, {:crashed, _}} = Maker.run({:crash, self()}, fn -> raise "boom" end, 5_000)
    assert :ok = Maker.run({:after_crash, self()}, fn -> :ok end, 5_000)
  end
end
