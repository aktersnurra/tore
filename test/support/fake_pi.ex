defmodule Tore.FakePi do
  @moduledoc """
  Points `Tore.Pi` at `test/support/bin/fake-pi` for a test, as `setup :fake_pi`. The fake keeps
  what Tore wrote to it in the file at `:pi_log`; `pi_records/1` reads it back. Set
  `FAKE_PI_REPLY` and `FAKE_PI_COST` to choose its answer.
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
      if previous,
        do: Application.put_env(:tore, :pi, previous),
        else: Application.delete_env(:tore, :pi)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Tore.Pi.Sessions),
          do: DynamicSupervisor.terminate_child(Tore.Pi.Sessions, pid)

      for var <- ~w(FAKE_PI_LOG FAKE_PI_REPLY FAKE_PI_COST), do: System.delete_env(var)
      File.rm(log)
    end)

    %{pi_log: log}
  end

  @doc "The header and RPC commands Tore wrote to the fake, decoded."
  def pi_records(log),
    do: log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
