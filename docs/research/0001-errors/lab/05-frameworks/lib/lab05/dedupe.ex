defmodule Lab05.Dedupe do
  @moduledoc "Spike: telemetry marks the process, the logger handler checks the mark."
  @events [[:phoenix, :router_dispatch, :exception], [:bandit, :request, :exception], [:cowboy, :request, :exception], [:phoenix, :live_view, :handle_event, :exception]]

  def start(pid) do
    :telemetry.attach_many("lab05-dedupe", @events, &__MODULE__.tel/4, pid)
    :logger.add_handler(:lab05_dedupe, __MODULE__, %{level: :error, config: %{pid: pid}})
  end

  def stop do
    :telemetry.detach("lab05-dedupe")
    :logger.remove_handler(:lab05_dedupe)
  end

  def tel(name, _m, meta, pid) do
    ex = unwrap(meta[:reason] || meta[:exception])
    Process.put(:lab05_seen, [ex | Process.get(:lab05_seen, [])])
    send(pid, {:dedupe_tel, name, ex})
  end

  def log(%{meta: %{crash_reason: {reason, _}}}, %{config: %{pid: pid}}) do
    ex = unwrap(reason)
    send(pid, {:dedupe_log, ex in Process.get(:lab05_seen, [])})
  end

  def log(_, _), do: :ok

  defp unwrap(%Plug.Conn.WrapperError{reason: r}), do: r
  defp unwrap({{%{__exception__: true} = e, _st}, _call}), do: e
  defp unwrap(r), do: r
end
