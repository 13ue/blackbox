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

  @doc """
  The store, for the host's supervision tree, right after its Repo:

      {Blackbox, repo: MyApp.Repo, build: "abc123", spool_dir: "/data/blackbox"}

  Needs `ecto_sql` and `postgrex`, and the tables (`mix blackbox.gen.migration`).
  Until it starts, captured failures wait in the buffer.
  """
  if Code.ensure_loaded?(Ecto.Adapters.SQL) do
    def child_spec(opts), do: Blackbox.Store.child_spec(opts)
  else
    def child_spec(_opts),
      do: raise(ArgumentError, "the Blackbox store needs :ecto_sql and :postgrex in your deps")
  end

  @doc "Adds a breadcrumb to the calling process's ring."
  def crumb(message, data \\ %{}), do: Blackbox.Crumbs.add(:crumb, message, data)

  @doc """
  Adds to this process's context, shown with any failure in it or in the
  processes it starts (Tasks find it through `$callers`). Scrubbed like
  everything else.

      Blackbox.set_context(%{hologram: {MyApp.Page, :save}})
  """
  def set_context(map) when is_map(map),
    do: Process.put(:blackbox_context, Map.merge(Process.get(:blackbox_context, %{}), map)) && :ok

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
