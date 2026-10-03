defmodule Blackbox.Event do
  @moduledoc false
  # Turns what :logger, the primary filter and telemetry see into
  # `{fingerprint, dedupe_key, sample}`. Runs in the failing process, so it
  # keeps raw terms: no inspect, no regexes, no I/O. `finish/1` formats a
  # sample later, in the buffer, only for the samples it keeps.

  @stdlib_apps [:erts, :kernel, :stdlib, :elixir, :logger, :compiler, :crypto, :telemetry]
  @max_words 65_536

  ## Sources

  # A :logger event seen by the handler (Elixir's translator has run).
  def from_log(%{level: level, msg: msg, meta: meta}) do
    case meta do
      %{crash_reason: {reason, stack}} when is_list(stack) ->
        {kind, reason, stack} = unwrap_exit({reason, stack}, stack)
        build(kind, reason, stack, :logger, meta, %{}, level)

      _ ->
        build(:log, msg, [], :logger, meta, %{}, level)
    end
  end

  # A raw OTP report seen by the primary filter, before the translator.
  # nil means: not a failure of its own.
  def from_report(label, r, meta, level) do
    case label do
      {:gen_server, :terminate} -> crash(:exit, r[:reason], [], meta, locals(r, r[:last_message]))
      {:gen_statem, :terminate} -> statem(r, meta)
      {:gen_event, :terminate} -> crash(:exit, r[:reason], [], meta, locals(r, r[:last_message]))
      {Task.Supervisor, :terminating} -> task(r[:report] || r, meta)
      {:proc_lib, :crash} -> proc_lib(r[:report], meta)
      {:supervisor, :child_terminated} -> child(r[:report], meta)
      {:supervisor, :start_error} -> child(r[:report], meta)
      {:supervisor, :shutdown} -> give_up(r[:report], meta)
      {:supervisor, _} -> child(r[:report], meta)
      {:application_controller, :exit} -> app_exit(r[:report], meta)
      _ -> build(:log, {:report, r}, [], :filter, Map.put(meta, :label, label), %{}, level)
    end
  end

  # A telemetry exception event (Phoenix, Plug, Bandit, telemetry itself).
  def from_telemetry(kind, reason, stack) do
    meta = %{pid: self()}

    case kind do
      :error -> crash(:error, reason, stack, meta, %{}, :telemetry)
      :throw -> build(:throw, reason, stack, :telemetry, meta, %{}, :error)
      :exit -> crash(:exit, reason, stack, meta, %{}, :telemetry)
    end
  end

  # Blackbox.capture_exception/3 and capture_message/2, in the calling process.
  def from_manual(:error, e, stack, context) do
    meta = %{pid: self()}
    e = normalize(e, stack)

    with {_, _, _} = t <- build(:error, e, stack, :manual, meta, %{}, :error),
         do: put_context(t, context)
  end

  def from_manual(:log, message, level, context) do
    # The call site is the frame below Blackbox's own (the public call may be a tail call).
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
    own? = fn {m, _, _, _} -> m in [Blackbox, Blackbox.Capture, Blackbox.Event] end
    site = stack |> Enum.drop_while(&(not own?.(&1))) |> Enum.drop_while(own?) |> List.first()

    meta =
      case site do
        {m, f, a, loc} ->
          %{
            pid: self(),
            mfa: {m, f, if(is_list(a), do: length(a), else: a)},
            line: loc[:line],
            file: loc[:file]
          }

        nil ->
          %{pid: self()}
      end

    build(:log, {:string, message}, [], :manual, meta, %{}, level) |> put_context(context)
  end

  # A browser error posted to the host: untrusted text, capped, grouped by
  # its name and its top 3 stack lines with every digit-bearing token masked
  # (line:col, bundle hashes).
  def from_browser(report, context) do
    cap = fn v, n -> v |> to_string() |> binary_part(0, min(byte_size(to_string(v)), n)) end

    lines =
      report
      |> Map.get(:stack, "")
      |> cap.(4_096)
      |> String.split("\n", trim: true)
      |> Enum.take(30)

    r = %{
      name: cap.(Map.get(report, :name, "Error"), 100),
      message: cap.(Map.get(report, :message, ""), 1_024),
      url: cap.(Map.get(report, :url, ""), 1_024),
      lines: lines
    }

    fp = hash([:browser, r.name, Enum.map(Enum.take(lines, 3), &mask/1)])

    sample = %{
      kind: :browser,
      level: :error,
      reason: r,
      stack: [],
      source: :browser,
      pid: nil,
      meta: %{callers: []},
      locals: %{},
      crumbs: [],
      caller_crumbs: [],
      context: context,
      system: %{},
      at: System.system_time(:microsecond)
    }

    {fp, nil, sample}
  end

  defp put_context({fp, key, sample}, context) when context == %{}, do: {fp, key, sample}

  defp put_context({fp, key, sample}, context),
    do: {fp, key, %{sample | context: Map.merge(sample.context, context)}}


  defp statem(r, meta) do
    reason =
      case r[:reason] do
        {class, reason, stack} -> {class, reason, stack}
        other -> {:exit, other, []}
      end

    last = List.first(r[:queue] || [])
    {class, reason, stack} = reason
    crash(class, reason, stack, meta, locals(r, last))
  end

  defp task(r, meta), do: crash(:exit, r[:reason], [], meta, %{})

  defp proc_lib([info | _], meta) when is_list(info) do
    {class, reason, stack} = info[:error_info]

    locals = %{
      message_queue_len: info[:message_queue_len],
      links: info[:links],
      ancestors: info[:ancestors]
    }

    meta =
      meta
      |> Map.put(:registered_name, name(info[:registered_name]))
      |> Map.put(:initial_call, info[:initial_call])
      |> Map.put(:process_label, label_of(info[:process_label]))

    crash(class, reason, stack, meta, locals)
  end

  defp proc_lib(_, _), do: nil

  defp child(r, meta) when is_list(r) do
    offender = r[:offender] || []
    pid = offender[:pid]

    cond do
      # The child reported this crash itself; the supervisor is a second witness.
      is_pid(pid) and :ets.take(Blackbox.Reported, pid) != [] -> :reported
      self_reported?(r[:reason]) -> :reported
      expected?(r[:reason]) -> :expected
      true -> build(:exit, r[:reason], [], :filter, child_meta(meta, pid, offender), %{}, :error)
    end
  end

  defp child(_, _), do: nil

  defp give_up(r, meta) when is_list(r) do
    meta = Map.merge(meta, %{process_label: {:supervisor, r[:supervisor]}})
    build(:exit, r[:reason], [], :filter, meta, %{}, :error)
  end

  defp give_up(_, _), do: nil

  defp app_exit(r, meta) when is_list(r) do
    meta = Map.put(meta, :process_label, {:application, r[:application]})

    if expected?(r[:exited]),
      do: :expected,
      else: build(:exit, r[:exited], [], :filter, meta, %{}, :error)
  end

  defp app_exit(_, _), do: nil

  defp child_meta(meta, pid, offender) do
    meta
    |> Map.put(:pid, pid)
    |> Map.put(:process_label, {:child, offender[:id]})
    |> Map.put(:initial_call, mfa(offender[:mfargs]))
  end

  # The supervisor's child_terminated for a crash the child already logged.
  defp self_reported?({%{__exception__: true}, st}) when is_list(st), do: true
  defp self_reported?({{:nocatch, _}, st}) when is_list(st), do: true
  defp self_reported?(_), do: false

  def expected?(:normal), do: true
  def expected?(:shutdown), do: true
  def expected?({:shutdown, _}), do: true
  def expected?(_), do: false

  defp locals(r, last) do
    %{
      last_message: last,
      state: r[:state],
      log: r[:log],
      client_info: client(r[:client_info]),
      name: r[:name]
    }
  end

  defp client({pid, {name, stack}}) when is_pid(pid),
    do: %{pid: pid, name: name, stack: arity(stack)}

  defp client({pid, other}) when is_pid(pid), do: %{pid: pid, status: other}
  defp client(_), do: nil

  ## Classification

  defp crash(class, reason, stack, meta, locals, source \\ :filter) do
    {kind, reason, stack} =
      case class do
        :error -> {:error, normalize(reason, stack), stack}
        :throw -> {:throw, reason, stack}
        _ -> unwrap_exit(reason, stack)
      end

    if kind == :exit and expected?(reason),
      do: :expected,
      else: build(kind, reason, stack, source, meta, locals, :error)
  end

  # An exit reason `{reason, stacktrace}` is how OTP carries a crash out of
  # a callback; take it apart so a raise is an :error with its own stack.
  defp unwrap_exit({%{__struct__: Plug.Conn.WrapperError, reason: r, stack: st}, _}, _),
    do: {:error, r, st}

  defp unwrap_exit({%{__exception__: true} = e, st}, _) when is_list(st), do: {:error, e, st}
  defp unwrap_exit({{:nocatch, v}, st}, _) when is_list(st), do: {:throw, v, st}

  defp unwrap_exit({r, [{_, _, _, _} | _] = st}, _) do
    case Exception.normalize(:error, r, st) do
      %ErlangError{} -> {:exit, r, st}
      e -> {:error, e, st}
    end
  end

  defp unwrap_exit(r, stack), do: {:exit, r, stack}

  defp normalize(%{__struct__: Plug.Conn.WrapperError, reason: r, stack: st}, _),
    do: normalize(r, st)

  defp normalize(reason, stack), do: Exception.normalize(:error, reason, stack)

  ## The sample

  defp build(kind, reason, stack, source, meta, locals, level) do
    pid = meta[:pid]
    in_process = pid == self()
    stack = arity(stack)
    callers = meta[:callers] || (in_process && Process.get(:"$callers")) || []
    client = locals[:client_info]
    caller = List.first(callers) || (client && client[:pid])

    meta =
      meta
      |> Map.take([
        :mfa,
        :line,
        :file,
        :domain,
        :registered_name,
        :initial_call,
        :process_label,
        :label
      ])
      |> Map.put(:callers, callers)
      |> put_process(in_process)

    sample = %{
      kind: kind,
      level: level,
      reason: bounded(reason),
      stack: stack,
      source: source,
      pid: pid,
      meta: meta,
      locals: Map.new(locals, fn {k, v} -> {k, bounded(v)} end),
      crumbs: if(in_process, do: Blackbox.Crumbs.own(), else: []),
      caller_crumbs: Blackbox.Crumbs.of(caller),
      context: context(in_process, caller),
      system: system(in_process),
      at: System.system_time(:microsecond)
    }

    key = if kind == :log, do: nil, else: :erlang.phash2({kind, reason})
    {fingerprint(kind, reason, stack, meta), key, sample}
  end

  # The context set with Blackbox.set_context/1, this process's over its caller's.
  defp context(in_process, caller) do
    own = if in_process, do: Process.get(:blackbox_context, %{}), else: %{}

    case is_pid(caller) && :erlang.process_info(caller, {:dictionary, :blackbox_context}) do
      {{:dictionary, :blackbox_context}, %{} = theirs} -> Map.merge(theirs, own)
      _ -> own
    end
  end

  # Fixed, sub-µs fields at the moment of failure; node memory from the
  # buffer's 1 s sampler (`:erlang.memory/0` costs 47 µs, 06-15).
  defp system(in_process) do
    process =
      if in_process,
        do: Map.new(Process.info(self(), [:message_queue_len, :memory, :reductions])),
        else: %{}

    Map.merge(process, %{
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      memory: Blackbox.Buffer.memory()
    })
  end

  defp put_process(meta, true) do
    meta
    |> Map.put_new(:process_label, label_of(:proc_lib.get_label(self())))
    |> Map.put_new(:registered_name, name(Process.info(self(), :registered_name)))
  end

  defp put_process(meta, false), do: meta

  defp label_of(:undefined), do: nil
  defp label_of(l), do: l

  defp name({:registered_name, n}), do: name(n)
  defp name([]), do: nil
  defp name(n) when is_atom(n), do: n
  defp name(_), do: nil

  defp mfa({m, f, a}) when is_list(a), do: {m, f, length(a)}
  defp mfa(other), do: other

  defp arity(stack) when is_list(stack) do
    for {m, f, a, loc} <- stack, do: {m, f, if(is_list(a), do: length(a), else: a), loc}
  end

  defp arity(_), do: []

  defp bounded(term) do
    case :erts_debug.flat_size(term) do
      words when words > @max_words -> {:too_big, words}
      _ -> term
    end
  end

  ## Fingerprint v1: kind, type, top 3 in-app frames; no lines, messages or args.

  def fingerprint(kind, reason, stack, meta \\ %{})

  def fingerprint(:log, msg, _, meta) do
    case meta do
      %{label: label} -> hash([:log, label, meta[:mfa]])
      %{mfa: mfa, line: line} -> hash([:log, mfa, line])
      _ -> hash([:log, template(msg)])
    end
  end

  def fingerprint(kind, reason, stack, meta) do
    frames =
      case frames(stack) do
        [] -> [{:process, meta[:process_label] || meta[:registered_name] || meta[:initial_call]}]
        frames -> frames
      end

    hash([kind, type(kind, reason), frames])
  end

  defp frames(stack) do
    {in_app, stdlib} = modules()
    app = top(stack, &Map.has_key?(in_app, &1))
    app = if app == [], do: top(stack, &(not Map.has_key?(stdlib, &1))), else: app
    if app == [], do: top(stack, fn _ -> true end), else: app
  end

  defp top(stack, keep?) do
    for(
      {m, f, a, _} <- stack,
      keep?.(m),
      do: {m, strip_fun(f), if(is_list(a), do: length(a), else: a)}
    )
    |> Enum.take(3)
  end

  # :application.get_application/1 costs 11 µs a call (08), so both sets are
  # built once. Without `config :blackbox, in_app: [...]`, every frame
  # outside OTP and Elixir counts as in-app.
  def modules do
    case :persistent_term.get({__MODULE__, :modules}, nil) do
      nil ->
        set = fn apps ->
          Map.new(for(app <- apps, m <- Application.spec(app, :modules) || [], do: {m, true}))
        end

        sets = {set.(Application.get_env(:blackbox, :in_app, [])), set.(@stdlib_apps)}
        :persistent_term.put({__MODULE__, :modules}, sets)
        sets

      sets ->
        sets
    end
  end

  def reset_modules, do: :persistent_term.erase({__MODULE__, :modules})

  # "-run/1-fun-3-" -> "-run/1-fun--": a new anonymous function earlier in
  # the module renumbers every later one.
  defp strip_fun(f) do
    case :binary.split(Atom.to_string(f), "-fun-", [:global]) do
      [name] -> name
      [head | rest] -> Enum.join([head | Enum.map(rest, &drop_digits/1)], "-fun-")
    end
  end

  defp drop_digits(<<d, rest::binary>>) when d in ?0..?9, do: drop_digits(rest)
  defp drop_digits(rest), do: rest

  def type(:log, _), do: :log
  def type(:throw, _), do: :throw
  def type(:error, %{__struct__: s}), do: s
  def type(:exit, r), do: shape(r)
  def type(kind, _), do: kind

  defp shape(r) when is_atom(r), do: r

  defp shape(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)),
    do: {elem(t, 0), :_}

  defp shape(_), do: :term

  # A log without a call site groups by its text with every token that
  # holds a digit masked: numbers, pids, refs, UUIDs, ids.
  defp template({:string, s}), do: s |> IO.chardata_to_string() |> mask()
  defp template({:report, r}) when is_map(r), do: {:report, r |> Map.keys() |> Enum.sort()}
  defp template({f, _}), do: {:format, f}
  defp template(s) when is_binary(s), do: mask(s)
  defp template(other), do: other

  def mask(text) do
    for word <- :binary.split(text, [" ", "\n", "\t"], [:global]) do
      if digit?(word), do: "<n>", else: word
    end
  end

  defp digit?(<<d, _::binary>>) when d in ?0..?9, do: true
  defp digit?(<<_, rest::binary>>), do: digit?(rest)
  defp digit?(<<>>), do: false

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> binary_part(0, 12)
    |> Base.encode16(case: :lower)
  end

  ## In the buffer: formatting for kept samples only (~20 µs a frame, 08).

  def finish(%{kind: kind} = s) do
    {in_app, _} = modules()
    alias Blackbox.Scrub
    # Scrubbed once, here, before anything is formatted.
    reason = Scrub.term(s.reason)

    %{
      kind: kind,
      type: type_text(kind, reason),
      message: kind |> message(reason, s.meta) |> Scrub.message(),
      stacktrace:
        if kind == :browser do
          for line <- reason.lines, do: %{text: Scrub.text(line), in_app: false}
        else
          for {m, _, _, _} = frame <- s.stack do
            %{text: Exception.format_stacktrace_entry(frame), in_app: Map.has_key?(in_app, m)}
          end
        end,
      ref: Map.get(s, :ref),
      url: if(kind == :browser, do: Scrub.text(reason.url)),
      source: source_text(s.source),
      level: s.level,
      pid: s.pid && inspect(s.pid),
      process_label: s.meta[:process_label] && inspect(Scrub.term(s.meta[:process_label])),
      registered_name: s.meta[:registered_name] && inspect(s.meta[:registered_name]),
      initial_call: s.meta[:initial_call] && inspect(s.meta[:initial_call]),
      mfa: s.meta[:mfa] && inspect(s.meta[:mfa]),
      callers: Enum.map(s.meta[:callers], &inspect/1),
      locals: for({k, v} <- s.locals, v != nil, into: %{}, do: {k, short(scrub_local(k, v))}),
      context:
        for(
          {k, v} <- Scrub.term(Map.get(s, :context, %{})),
          into: %{},
          do: {to_string(k), short(v)}
        ),
      system: Map.get(s, :system, %{}),
      crumbs: crumbs(s.crumbs),
      caller_crumbs: crumbs(s.caller_crumbs),
      at: s.at
    }
  end

  defp scrub_local(:log, v), do: Blackbox.Scrub.sys_log(v)
  defp scrub_local(_, v), do: Blackbox.Scrub.term(v)

  defp source_text(source) when is_atom(source), do: to_string(source)
  defp source_text({:filter, label}), do: "filter " <> inspect(label)
  defp source_text(event) when is_list(event), do: Enum.join(event, ".")
  defp source_text(other), do: inspect(other)

  def type_text(:browser, %{name: name}), do: "browser " <> name
  def type_text(:error, %{__struct__: s}), do: inspect(s)
  def type_text(:exit, r), do: "exit " <> shape_text(shape(r))
  def type_text(kind, _), do: to_string(kind)

  defp shape_text({tag, :_}), do: "{#{inspect(tag)}, _}"
  defp shape_text(other), do: inspect(other)

  defp message(:log, msg, meta), do: text(msg, meta)
  defp message(:browser, r, _), do: "#{r.name}: #{r.message}"
  defp message(:error, %{__exception__: true} = e, _), do: safe(fn -> Exception.message(e) end)
  defp message(_, r, _), do: short(r)

  defp crumbs(list) do
    for {at, level, msg, data} <- list do
      %{
        at: at,
        level: level,
        message: text(msg, %{}),
        data: if(data == %{}, do: nil, else: short(data))
      }
    end
  end

  def text({:string, s}, _), do: IO.chardata_to_string(s)

  def text({:report, r}, %{report_cb: cb}) when is_function(cb, 1),
    do: safe(fn -> cb.(r) |> format() end)

  def text({:report, r}, _), do: short(r)
  def text({f, a}, _) when is_list(a), do: safe(fn -> format({f, a}) end)
  def text(s, _) when is_binary(s), do: s
  def text(other, _), do: short(other)

  defp format({f, a}), do: f |> :io_lib.format(a) |> IO.chardata_to_string()

  defp safe(fun) do
    fun.()
  rescue
    _ -> "(unprintable)"
  end

  defp short(t), do: inspect(t, limit: 50, printable_limit: 1024)
end
