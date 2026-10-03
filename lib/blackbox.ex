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

  @doc """
  Captures a rescued exception, which no hook sees. Returns its ref.

      rescue
        e -> Blackbox.capture_exception(e, __STACKTRACE__, context: %{board: id})

  If the same exception later crashes the process, that is the same failure,
  not a second one.
  """
  def capture_exception(exception, stacktrace, opts \\ []) do
    context = Map.new(opts[:context] || %{})

    Blackbox.Capture.manual(
      fn -> Blackbox.Event.from_manual(:error, exception, stacktrace, context) end,
      :manual
    )
  end

  @doc "Captures a message as a failure of its own, grouped by call site. Returns its ref."
  def capture_message(message, opts \\ []) when is_binary(message) do
    context = Map.new(opts[:context] || %{})
    level = opts[:level] || :error

    Blackbox.Capture.manual(
      fn -> Blackbox.Event.from_manual(:log, message, level, context) end,
      :manual
    )
  end

  @doc """
  Captures an error a browser reported to the host, as
  `%{name: _, message: _, stack: _, url: _}`. Anyone who can reach the
  host's endpoint can write here: it is stored as `source: browser`,
  marked untrusted in Markdown, and left out of the default API listing.
  Rate-limit it in the host.
  """
  def capture_browser(report, opts \\ []) when is_map(report) do
    # Only these fields, from string or atom keys; everything else is ignored.
    report =
      for k <- [:name, :message, :stack, :url],
          v = report[k] || report[to_string(k)],
          v != nil,
          into: %{},
          do: {k, v}

    context = Map.new(opts[:context] || %{})
    Blackbox.Capture.manual(fn -> Blackbox.Event.from_browser(report, context) end, :browser)
  end

  @doc """
  The ref of the last failure captured in this process, for an error page
  or a JSON error ("Reference a1b2c3-x9k2"); nil if there was none.
  """
  def current_ref, do: Process.get(:blackbox_ref)

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
