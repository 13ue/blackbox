defmodule Lab05.Capture do
  @moduledoc "Test :logger handler + :telemetry handler that forward everything to a pid."

  @events [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :start],
    [:phoenix, :router_dispatch, :stop],
    [:phoenix, :router_dispatch, :exception],
    [:phoenix, :error_rendered],
    [:phoenix, :socket_connected],
    [:phoenix, :channel_joined],
    [:phoenix, :channel_handled_in],
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_params, :exception],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_view, :render, :exception],
    [:phoenix, :live_component, :handle_event, :exception],
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception],
    [:cowboy, :request, :start],
    [:cowboy, :request, :stop],
    [:cowboy, :request, :exception],
    [:cowboy, :request, :early_error],
    [:plug, :router_dispatch, :exception],
    [:lab05, :repo, :query],
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:oban, :engine, :insert_job, :exception],
    [:oban, :plugin, :exception],
    [:oban, :queue, :shutdown],
    [:finch, :request, :stop],
    [:finch, :request, :exception],
    [:finch, :connect, :stop],
    [:finch, :send, :stop],
    [:finch, :recv, :exception]
  ]

  def events, do: @events

  def start(pid \\ self()) do
    stop()
    :ok = :logger.add_handler(:lab05_capture, __MODULE__, %{level: :all, config: %{pid: pid}})
    :ok = :telemetry.attach_many("lab05-capture", @events, &__MODULE__.handle_telemetry/4, pid)
    :ok
  end

  def stop do
    :logger.remove_handler(:lab05_capture)
    :telemetry.detach("lab05-capture")
    :ok
  end

  # :logger handler callback, runs in the process that logged
  def log(event, %{config: %{pid: pid}}) do
    send(pid, {:log, self(), event})
  end

  def handle_telemetry(name, meas, meta, pid) do
    send(pid, {:tel, self(), name, meas, meta})
  end

  @doc "Collect all messages that arrive within `ms` of quiet."
  def collect(ms \\ 300), do: collect(ms, [])

  @doc "Collect everything that arrives during exactly `ms`."
  def collect_for(ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    Stream.repeatedly(fn ->
      left = max(deadline - System.monotonic_time(:millisecond), 0)
      receive do
        {:log, _, _} = m -> m
        {:tel, _, _, _, _} = m -> m
      after
        left -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end

  defp collect(ms, acc) do
    receive do
      {:log, _, _} = m -> collect(ms, [m | acc])
      {:tel, _, _, _, _} = m -> collect(ms, [m | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  def logs(msgs, min_level \\ :warning) do
    for {:log, pid, e} <- msgs, :logger.compare_levels(e.level, min_level) != :lt, do: Map.put(e, :from, pid)
  end

  def tels(msgs, suffix) do
    for {:tel, pid, name, meas, meta} <- msgs, List.last(name) == suffix,
        do: %{name: name, meas: meas, meta: meta, from: pid}
  end

  def names(msgs), do: for({:tel, _, name, _, _} <- msgs, do: name)

  @doc "Short text form of a log event."
  def text(%{msg: {:string, s}}), do: IO.chardata_to_string(s)
  def text(%{msg: {:report, r}, meta: meta}) do
    case meta do
      %{report_cb: cb} when is_function(cb, 1) -> cb.(r) |> then(fn {f, a} -> :io_lib.format(f, a) |> IO.chardata_to_string() end)
      _ -> inspect(r)
    end
  end
  def text(%{msg: {f, a}}), do: :io_lib.format(f, a) |> IO.chardata_to_string()
end
