defmodule Blackbox.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Pids that reported their own crash, so a supervisor's child_terminated
    # for the same death is not counted twice. Owned by the application master.
    :ets.new(Blackbox.Reported, [:named_table, :public, :set, write_concurrency: true])

    children = [
      {Task.Supervisor, name: Blackbox.TaskSup},
      Blackbox.Buffer,
      Blackbox.Capture
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Blackbox.Supervisor)
  end
end
