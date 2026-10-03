defmodule Blackbox.Capture do
  @moduledoc false
  # The install sequence and its watchdog. The filter, the handler and the
  # telemetry callbacks below run in the process that logged or raised:
  # cheap, bounded, and wrapped, because OTP removes a filter or handler that
  # raises and telemetry detaches one.
  use GenServer
  alias Blackbox.{Buffer, Crumbs, Event}

  @handler :blackbox
  @filter :blackbox_sasl
  @telemetry_id "blackbox"
  @telemetry [
    [:phoenix, :router_dispatch, :exception],
    [:phoenix, :error_rendered],
    [:plug, :router_dispatch, :exception],
    [:bandit, :request, :exception],
    [:telemetry, :handler, :failure],
    # crumbs; Bandit runs every keep-alive request of a connection in one
    # process (06-42), so a request start resets the ring
    [:bandit, :request, :start],
    [:phoenix, :endpoint, :start],
    [:phoenix, :router_dispatch, :start],
    [:finch, :request, :stop]
  ]
  @check_ms 5_000
  @give_up {5, 600_000}
  @dedupe_ms 1_000
  @marks 8

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def pause, do: GenServer.call(__MODULE__, :pause)
  def resume, do: GenServer.call(__MODULE__, :resume)
  def check, do: GenServer.call(__MODULE__, :check)

  def telemetry_events, do: @telemetry

  ## Watchdog

  @impl true
  def init(_) do
    Logger.metadata(blackbox: true)

    if Application.get_env(:blackbox, :capture, true) do
      :erlang.system_flag(:backtrace_depth, Application.get_env(:blackbox, :backtrace_depth, 32))
      Event.modules()
      install()
      Process.send_after(self(), :check, @check_ms)
      {:ok, %{state: :on, readds: []}}
    else
      {:ok, %{state: :off, readds: []}}
    end
  end

  @impl true
  def handle_call(:pause, _, s) do
    uninstall()
    {:reply, :ok, %{s | state: :paused}}
  end

  def handle_call(:resume, _, s) do
    install()
    {:reply, :ok, %{s | state: :on, readds: []}}
  end

  def handle_call(:check, _, s), do: {:reply, :ok, check(s)}

  @impl true
  def handle_info(:check, s) do
    Process.send_after(self(), :check, @check_ms)
    {:noreply, check(s)}
  end

  defp check(%{state: :on} = s) do
    case install() do
      [] ->
        s

      missing ->
        Blackbox.bump(:reinstalled)
        now = System.monotonic_time(:millisecond)
        {max, window} = @give_up
        readds = [now | Enum.filter(s.readds, &(now - &1 < window))]

        if length(readds) > max do
          uninstall()

          own(
            :gave_up,
            "capture gave up after #{max} re-installs in #{div(window, 60_000)} min: #{inspect(missing)}"
          )

          %{s | state: :gave_up, readds: readds}
        else
          own(
            :capture_off,
            "capture was off for up to #{div(@check_ms, 1000)} s: #{inspect(missing)} re-installed"
          )

          %{s | readds: readds}
        end
    end
  end

  defp check(s), do: s

  # Installs whatever is missing; returns what was.
  defp install do
    filter =
      case Keyword.keys(:logger.get_primary_config().filters) do
        [@filter | _] ->
          []

        ids ->
          # add_primary_filter prepends (04-71): ours runs before Elixir's translator.
          if @filter in ids, do: :logger.remove_primary_filter(@filter)
          :ok = :logger.add_primary_filter(@filter, {&__MODULE__.filter/2, nil})
          if @filter in ids, do: [:filter_order], else: [:filter]
      end

    handler =
      if @handler in :logger.get_handler_ids(),
        do: [],
        else: :logger.add_handler(@handler, __MODULE__, %{level: :all}) && [:handler]

    telemetry =
      if Enum.any?(:telemetry.list_handlers([]), &(&1.id == @telemetry_id)),
        do: [],
        else:
          :telemetry.attach_many(@telemetry_id, @telemetry, &__MODULE__.handle_telemetry/4, nil) &&
            [:telemetry]

    filter ++ handler ++ telemetry
  end

  defp uninstall do
    :logger.remove_primary_filter(@filter)
    :logger.remove_handler(@handler)
    :telemetry.detach(@telemetry_id)
  end

  # The lib's own events: the [:blackbox] domain keeps them out of the handler.
  defp own(what, message) do
    sample = %{
      kind: :log,
      level: :error,
      reason: {:string, message},
      stack: [],
      source: :blackbox,
      pid: self(),
      meta: %{callers: []},
      locals: %{},
      crumbs: [],
      caller_crumbs: [],
      at: System.system_time(:microsecond)
    }

    push(Event.fingerprint(:log, {:string, message}, [], %{label: {:blackbox, what}}), sample)
  end

  ## Primary filter: raw OTP reports, before the translator turns them into
  ## text (Elixir 1.18) or stops them (every [:otp, :sasl] report, 04-15).

  def filter(%{msg: {:report, %{label: label} = r}, level: level, meta: meta}, _) do
    if take?(label, level, meta) and not reentry?() do
      # The same event reaches the handler next (translated); it skips it.
      Process.put(:blackbox_took, meta[:time])

      capture(
        fn -> Event.from_report(label, r, meta, level) end,
        meta[:pid] == self(),
        {:filter, label}
      )
    end

    :ignore
  catch
    _, _ ->
      Process.delete(:blackbox_in)
      Blackbox.bump(:handler_errors)
      :ignore
  end

  def filter(_, _), do: :ignore

  defp take?(_, _, %{blackbox: true}), do: false
  defp take?(_, _, %{domain: [d | _]}) when d in [:blackbox, :telemetry], do: false
  defp take?({:application_controller, :exit}, _, _), do: true
  defp take?(_, level, _), do: :logger.compare_levels(level, :error) != :lt

  ## :logger handler, level :all: the primary level decides what arrives.

  def log(%{meta: %{blackbox: true}}, _), do: :ok
  def log(%{meta: %{domain: [d | _]}}, _) when d in [:blackbox, :telemetry], do: :ok

  def log(%{level: level, meta: meta} = event, _config) do
    cond do
      reentry?() ->
        :ok

      meta[:time] != nil and Process.get(:blackbox_took) == meta[:time] ->
        Process.delete(:blackbox_took)

      :logger.compare_levels(level, :error) == :lt ->
        if meta[:pid] == self(), do: Crumbs.add(level, event.msg, crumb_meta(meta))

      true ->
        capture(fn -> Event.from_log(event) end, meta[:pid] == self(), :logger)
    end

    :ok
  catch
    _, _ ->
      Process.delete(:blackbox_in)
      Blackbox.bump(:handler_errors)
      :ok
  end

  defp crumb_meta(%{report_cb: _} = meta), do: Map.take(meta, [:report_cb])
  defp crumb_meta(_), do: %{}

  ## Telemetry

  @doc false
  # Ecto's event name has the host repo's prefix; the store attaches it.
  def attach_query(event),
    do:
      :telemetry.attach(
        "blackbox-query-" <> inspect(event),
        event,
        &__MODULE__.handle_telemetry/4,
        nil
      )

  def detach_query(event), do: :telemetry.detach("blackbox-query-" <> inspect(event))

  def handle_telemetry(event, measure, meta, _) do
    reason = meta[:reason] || meta[:exception]

    cond do
      reentry?() ->
        :ok

      crumb(event, measure, meta) ->
        :ok

      reason == nil ->
        :ok

      expected?(event, meta, reason) ->
        Blackbox.bump(:expected)

      true ->
        capture(
          fn -> Event.from_telemetry(meta[:kind] || :error, reason, meta[:stacktrace] || []) end,
          true,
          event
        )
    end

    :ok
  catch
    _, _ ->
      Process.delete(:blackbox_in)
      Blackbox.bump(:handler_errors)
      :ok
  end

  # Each crumb source with a short allow-list of fields: never params, bodies or headers.
  defp crumb([:bandit, :request, :start], _, _), do: Crumbs.reset()

  defp crumb([:phoenix, :endpoint, :start], _, %{conn: conn}) do
    Crumbs.reset()
    Crumbs.add(:request, {:string, "#{conn.method} #{conn.request_path}"})
  end

  defp crumb([:phoenix, :router_dispatch, :start], _, meta),
    do:
      Crumbs.add(:route, {:string, "#{meta[:route]} #{inspect(meta[:plug])}.#{meta[:plug_opts]}"})

  defp crumb([:finch, :request, :stop], %{duration: d}, %{request: req} = meta) do
    status =
      case meta[:result] do
        {:ok, %{status: status}} -> status
        {:error, e} -> inspect(e.__struct__)
        _ -> "?"
      end

    Crumbs.add(:http, {:string, "#{req.method} #{req.host} #{status} #{ms(d)} ms"})
  end

  defp crumb(event, measure, %{repo: _} = meta) do
    if List.last(event) == :query do
      result = if match?({:ok, _}, meta[:result]), do: "ok", else: "error"

      Crumbs.add(
        :query,
        {:string, "query #{meta[:source] || "-"} #{result} #{ms(measure[:total_time] || 0)} ms"}
      )
    end
  end

  defp crumb(_, _, _), do: false

  defp ms(native),
    do: Float.round(System.convert_time_unit(native, :native, :microsecond) / 1000, 1)

  defp expected?([:phoenix, :error_rendered], %{status: status}, _) when status < 500, do: true

  defp expected?(_, meta, reason) do
    meta[:kind] in [:error, nil] and plug_status(reason) < 500
  end

  defp plug_status(%{__struct__: Plug.Conn.WrapperError, reason: r}), do: plug_status(r)

  defp plug_status(%{__exception__: true} = e) do
    if Code.ensure_loaded?(Plug.Exception), do: apply(Plug.Exception, :status, [e]), else: 500
  end

  defp plug_status(_), do: 500

  ## One failure, one occurrence

  defp reentry?, do: Process.get(:blackbox_in) == true

  defp capture(build, in_process, source) do
    Process.put(:blackbox_in, true)

    case build.() do
      {fp, key, sample} -> sighting(fp, key, %{sample | source: source}, in_process, source)
      :expected -> Blackbox.bump(:expected)
      :reported -> Blackbox.bump(:deduped)
      nil -> :ok
    end

    Process.delete(:blackbox_in)
  end

  defp sighting(fp, key, sample, in_process, source) do
    if in_process and key != nil and seen?(key, source) do
      Blackbox.bump(:deduped)
    else
      if in_process and sample.kind != :log and is_pid(sample.pid),
        do: :ets.insert(Blackbox.Reported, {sample.pid, System.monotonic_time(:millisecond)})

      push(fp, sample)
    end
  end

  # A mark per failure in this process: `{key, sources, at}`. A second
  # source for the same key within 1 s is the same failure (telemetry, then
  # the log; the gen_server report, then the proc_lib report). The same
  # source again is a new failure and counts (10-1).
  defp seen?(key, source) do
    now = System.monotonic_time(:millisecond)
    marks = for {_, _, at} = m <- Process.get(:blackbox_marks, []), now - at < @dedupe_ms, do: m

    {seen, marks} =
      case List.keyfind(marks, key, 0) do
        {^key, sources, at} ->
          if source in sources,
            do: {false, [{key, [source], now} | List.keydelete(marks, key, 0)]},
            else: {true, List.keyreplace(marks, key, 0, {key, [source | sources], at})}

        nil ->
          {false, [{key, [source], now} | marks]}
      end

    Process.put(:blackbox_marks, Enum.take(marks, @marks))
    seen
  end

  defp push(fp, sample) do
    Blackbox.bump(:captured)
    Buffer.push({fp, sample})
  end
end
