defmodule Tore.FakePi do
  @moduledoc """
  Points `Tore.Pi` at `test/support/bin/fake-pi` for a test, as `setup :fake_pi`. The fake keeps
  what Tore wrote to it in the file at `:pi_log`; `pi_records/1` reads it back. Set
  `FAKE_PI_REPLY` and `FAKE_PI_COST` to choose its answer, `FAKE_PI_TOOL` for a tool call it
  makes first, `FAKE_PI_HISTORY` for the conversation it already has, and `FAKE_PI_WAIT` to a
  file it waits for before answering (`release/1` creates it).
  """

  import ExUnit.Callbacks

  @command Path.expand("bin/fake-pi", __DIR__)

  def fake_pi(_context) do
    log = Path.join(System.tmp_dir!(), "fake-pi-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:tore, :pi)

    Application.put_env(:tore, :pi,
      command: [@command],
      mcp_url: "http://tore.test/mcp",
      model: "anthropic/claude-sonnet-5-5"
    )

    System.put_env("FAKE_PI_LOG", log)

    on_exit(fn ->
      # A held fake lets go, so its session can stop.
      File.touch(log <> ".release")

      if previous,
        do: Application.put_env(:tore, :pi, previous),
        else: Application.delete_env(:tore, :pi)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Tore.Pi.Sessions),
          do: DynamicSupervisor.terminate_child(Tore.Pi.Sessions, pid)

      for var <-
            ~w(FAKE_PI_LOG FAKE_PI_REPLY FAKE_PI_COST FAKE_PI_TOOL FAKE_PI_HISTORY FAKE_PI_WAIT),
          do: System.delete_env(var)

      File.rm(log)
      File.rm(log <> ".messages")
      File.rm(log <> ".release")
    end)

    %{pi_log: log}
  end

  @doc "Makes the fake hold its answers until `release/1`."
  def hold(log), do: System.put_env("FAKE_PI_WAIT", log <> ".release")

  @doc "Lets a held fake answer."
  def release(log), do: File.touch!(log <> ".release")

  @doc "The header and RPC commands Tore wrote to the fake, decoded; none before it has started."
  def pi_records(log) do
    case File.read(log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end
end
