defmodule Lab05.Workers do
  defmodule Raise do
    use Oban.Worker, max_attempts: 3
    @impl true
    def perform(%{args: %{"secret" => _}}), do: raise("boom in job")
  end

  defmodule Last do
    use Oban.Worker, max_attempts: 1
    @impl true
    def perform(_), do: raise("boom on last attempt")
  end

  defmodule ErrorTuple do
    use Oban.Worker
    @impl true
    def perform(_), do: {:error, "nope"}
  end

  defmodule Cancel do
    use Oban.Worker
    @impl true
    def perform(_), do: {:cancel, "no longer needed"}
  end

  defmodule Snooze do
    use Oban.Worker
    @impl true
    def perform(_), do: {:snooze, 60}
  end

  defmodule Slow do
    use Oban.Worker
    @impl true
    def timeout(_), do: 50
    @impl true
    def perform(_), do: Process.sleep(1000)
  end

  defmodule Kill do
    use Oban.Worker
    @impl true
    def perform(_), do: Process.exit(self(), :kill)
  end

  defmodule Exit do
    use Oban.Worker
    @impl true
    def perform(_), do: exit(:bye)
  end

  defmodule Spawns do
    use Oban.Worker
    @impl true
    def perform(_) do
      Task.start(fn -> raise "boom in task from job" end)
      Process.sleep(50)
      :ok
    end
  end
end
