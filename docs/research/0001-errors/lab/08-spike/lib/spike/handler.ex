defmodule Spike.Handler do
  @moduledoc """
  :logger handler + :telemetry handler. Both run in the process that logged or raised,
  so everything here is cheap, bounded and wrapped: a raise here would detach us.
  """
  @dedupe_ms 1_000

  def attach(telemetry_events) do
    :logger.add_handler(:spike, __MODULE__, %{level: :all})
    :telemetry.attach_many("spike", telemetry_events, &__MODULE__.handle_telemetry/4, nil)
  end

  # :logger callback
  def log(%{meta: %{spike: true}}, _), do: :ok

  def log(%{level: level, msg: msg, meta: meta} = event, _config) do
    if :logger.compare_levels(level, :error) == :lt do
      if meta[:pid] == self(), do: Spike.Crumbs.add(level, msg)
    else
      capture(fn -> Spike.Event.from_log(event) end, meta[:pid] == self())
    end
  catch
    _, _ -> Spike.bump(:handler_errors)
  end

  # :telemetry callback, e.g. [:phoenix, :router_dispatch, :exception]
  def handle_telemetry(_event, _measure, %{kind: kind, reason: reason, stacktrace: stack}, _) do
    capture(fn -> Spike.Event.from_telemetry(kind, reason, stack) end, true)
  catch
    _, _ -> Spike.bump(:handler_errors)
  end

  def handle_telemetry(_, _, _, _), do: :ok

  defp capture(build, in_process) do
    case build.() do
      nil -> :ok
      event -> capture_event(event, in_process)
    end
  end

  defp capture_event({fp, type, sample}, in_process) do
    # One failure is often reported twice in the same process (telemetry then crash report,
    # or gen_server report then proc_lib report). Remember the last one per process.
    if in_process and sample.kind != :log and seen?({fp, sample.message}) do
      :ok
    else
      Spike.bump(:captured)
      Spike.Buffer.push({fp, type, sample})
    end
  end

  defp seen?(key) do
    now = System.monotonic_time(:millisecond)
    last = Process.put(:spike_last, {key, now})
    match?({^key, t} when now - t < @dedupe_ms, last)
  end
end
