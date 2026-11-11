defmodule ToreWeb.Background do
  @moduledoc """
  Slow work a LiveView starts and hears back from, such as a Capture turn or a planner command.

  The work runs under `Tore.TaskSupervisor` with the caller's Gettext locale, and its result is
  sent to the LiveView as `reply.(result)`. If the work raises or exits, the LiveView gets
  `reply.({:error, :crashed})` instead of nothing, so a screen never stays on "Thinking…".
  """

  require Logger

  @spec run((-> result), (result | {:error, :crashed} -> term())) :: :ok when result: term()
  def run(work, reply) when is_function(work, 0) and is_function(reply, 1) do
    pid = self()
    locale = Gettext.get_locale(ToreWeb.Gettext)

    {:ok, _task} =
      Task.Supervisor.start_child(Tore.TaskSupervisor, fn ->
        # Gettext's locale is per process, so any text the work writes needs it set here too.
        Gettext.put_locale(ToreWeb.Gettext, locale)

        result =
          try do
            work.()
          catch
            kind, reason ->
              Logger.error(Exception.format(kind, reason, __STACKTRACE__))
              {:error, :crashed}
          end

        send(pid, reply.(result))
      end)

    :ok
  end
end
