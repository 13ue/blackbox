defmodule Blackbox do
  @moduledoc """
  A flight recorder for the BEAM: every failure it can see, and what came
  before it.

  Capture starts with the `:blackbox` application. It installs a primary
  `:logger` filter (`:blackbox_sasl`), a `:logger` handler (`:blackbox`) and
  telemetry handlers, raises `:backtrace_depth` to 32, and checks every 5 s
  that all of them are still there.

  ## Configuration

      config :blackbox,
        capture: true,          # false: install nothing (for a host's test suite)
        backtrace_depth: 32,
        in_app: [:my_app]       # the host's apps; their frames decide grouping
  """

  @stats [
    :captured,
    :deduped,
    :dropped,
    :expected,
    :handler_errors,
    :writer_failures,
    :inflight,
    :reinstalled
  ]

  @doc "Adds a breadcrumb to the calling process's ring."
  def crumb(message, data \\ %{}), do: Blackbox.Crumbs.add(:crumb, message, data)

  @doc "Removes the handler, the filter and the telemetry handlers until `resume/0`."
  defdelegate pause(), to: Blackbox.Capture

  @doc "Installs capture again after `pause/0`."
  defdelegate resume(), to: Blackbox.Capture

  @doc "What was captured, deduped, dropped and lost, since boot."
  def stats, do: Map.new(Enum.with_index(@stats, 1), fn {k, i} -> {k, :atomics.get(ref(), i)} end)

  @doc false
  def bump(key, n \\ 1), do: :atomics.add_get(ref(), index(key), n)

  defp ref do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        r = :atomics.new(length(@stats), signed: true)
        :persistent_term.put(__MODULE__, r)
        r

      r ->
        r
    end
  end

  for {k, i} <- Enum.with_index(@stats, 1), do: defp(index(unquote(k)), do: unquote(i))
end
