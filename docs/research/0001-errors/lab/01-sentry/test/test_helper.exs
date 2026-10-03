ExUnit.start()

defmodule Lab01.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Lab01.Case
    end
  end

  setup do
    Process.register(self(), :lab01_sink)
    on_exit(fn -> :logger.remove_handler(:lab_sentry) end)
    :ok
  end

  def attach(config \\ %{}) do
    :ok = :logger.add_handler(:lab_sentry, Sentry.LoggerHandler, %{config: config})
  end

  # Collect every {:captured, event} arriving within `ms`.
  def captured(ms \\ 300), do: collect(:captured, ms)
  def sent(ms \\ 300), do: collect(:sent, ms)

  defp collect(tag, ms) do
    receive do
      {^tag, e} -> [e | collect(tag, ms)]
    after
      ms -> []
    end
  end

  def title(%Sentry.Event{exception: [%{type: t, value: v} | _]}), do: "#{t}: #{v}"
  def title(%Sentry.Event{message: %{formatted: f}}), do: f
end
