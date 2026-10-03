defmodule Spike.Application do
  @moduledoc false
  use Application

  @telemetry [[:app, :req, :exception], [:phoenix, :router_dispatch, :exception],
              [:bandit, :request, :exception], [:oban, :job, :exception]]

  @impl true
  def start(_type, _args) do
    children = [
      Spike.Repo,
      {Task.Supervisor, name: Spike.TaskSup},
      {Spike.Buffer, Spike.Store.writer(Spike.Repo)}
    ]

    with {:ok, sup} <- Supervisor.start_link(children, strategy: :one_for_one, name: Spike.Supervisor) do
      Spike.Store.setup!(Spike.Repo)
      Spike.Handler.attach(@telemetry)
      {:ok, sup}
    end
  end

  @impl true
  def stop(_), do: :logger.remove_handler(:spike)
end
