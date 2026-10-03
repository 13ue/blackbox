defmodule Spike.Event do
  @moduledoc "Turns logger and telemetry events into one normalized sample + fingerprint."
  @skip_apps [:elixir, :stdlib, :kernel, :logger, :telemetry, :erts]

  # A logger event at :error or above -> {fingerprint, type, sample}.
  def from_log(%{msg: {:report, %{label: {:supervisor, :child_terminated}, report: r}} = msg, meta: meta}) do
    case r[:reason] do
      # The child logged this crash itself (gen_server/Task report): not a new failure.
      {%{__exception__: true}, _} -> nil
      {{:nocatch, _}, _} -> nil
      # A kill or an exit the child could not report: the supervisor is the only witness.
      reason -> build({:exit, reason}, [], msg, Map.put(meta, :pid, r[:offender][:pid]), :logger)
    end
  end

  # The supervisor gave up (max restart intensity): a failure of its own, no crash_reason meta.
  def from_log(%{msg: {:report, %{label: {:supervisor, :shutdown}, report: r}} = msg, meta: meta}) do
    build({:exit, r[:reason]}, [], msg, meta, :logger)
  end

  def from_log(%{msg: msg, meta: meta}) do
    case meta do
      %{crash_reason: {reason, stack}} -> build(classify(reason, stack), stack, msg, meta, :logger)
      _ -> build({:log, text(msg)}, [], msg, meta, :logger)
    end
  end

  def from_telemetry(kind, reason, stack) do
    reason = if kind == :error, do: Exception.normalize(:error, reason, stack), else: reason
    build({kind, reason}, stack, nil, %{pid: self()}, :telemetry)
  end

  defp classify({:nocatch, v}, _), do: {:throw, v}
  defp classify(%{__exception__: true} = e, _), do: {:error, e}
  defp classify(reason, _), do: {:exit, reason}

  defp build({kind, reason}, stack, msg, meta, source) do
    in_process = meta[:pid] == self()
    report = case msg do {:report, r} when is_map(r) -> r; _ -> %{} end

    sample = %{
      kind: kind,
      message: message(kind, reason),
      # raw (args replaced by arity); formatted in the buffer only for kept samples, see finish/1
      stacktrace: Enum.map(stack, fn {m, f, a, loc} -> {m, f, if(is_list(a), do: length(a), else: a), loc} end),
      pid: inspect(meta[:pid]),
      label: if(in_process, do: label(), else: nil),
      mfa: if(meta[:mfa], do: inspect(meta[:mfa])),
      callers: Enum.map(meta[:callers] || [], &inspect/1),
      last_message: short(report[:last_message]),
      state: short(report[:state]),
      source: source,
      crumbs: if(in_process, do: Spike.Crumbs.own(), else: []),
      caller_crumbs: Spike.Crumbs.of(List.first(meta[:callers] || [])),
      at: System.system_time(:microsecond)
    }

    {fingerprint(kind, reason, stack), type(kind, reason), sample}
  end

  def fingerprint(:log, msg, _), do: hash(["log", normalize_text(msg)])

  def fingerprint(kind, reason, stack) do
    frames =
      stack
      |> Enum.reject(fn {m, _, _, _} -> MapSet.member?(skip_modules(), m) end)
      |> Enum.take(3)
      |> Enum.map(fn {m, f, a, _} -> {m, strip_fun(f), if(is_list(a), do: length(a), else: a)} end)

    hash([kind, type(kind, reason), frames])
  end

  # :application.get_application/1 costs ~11 µs a call, so the set is built once.
  defp skip_modules do
    case :persistent_term.get({__MODULE__, :skip}, nil) do
      nil ->
        set = MapSet.new(for app <- @skip_apps, m <- Application.spec(app, :modules) || [], do: m)
        :persistent_term.put({__MODULE__, :skip}, set)
        set

      set ->
        set
    end
  end

  # Runs in the buffer, only for the few samples it keeps: formatting costs ~20 µs a frame.
  def finish(sample) do
    %{sample | stacktrace: Enum.map(sample.stacktrace, &Exception.format_stacktrace_entry/1),
               crumbs: Spike.Crumbs.format(sample.crumbs), caller_crumbs: Spike.Crumbs.format(sample.caller_crumbs)}
  end

  def type(:log, _), do: "log"
  def type(:throw, _), do: "throw"
  def type(:error, %{__struct__: s}), do: inspect(s)
  def type(:exit, r), do: "exit " <> shape(r)
  def type(kind, _), do: to_string(kind)

  defp shape(r) when is_atom(r), do: inspect(r)
  defp shape(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)), do: "{#{inspect(elem(t, 0))}, _}"
  defp shape(_), do: "term"

  defp message(:log, text), do: text
  defp message(:error, e), do: Exception.message(e)
  defp message(_, r), do: short(r)

  defp strip_fun(f), do: f |> Atom.to_string() |> String.replace(~r/-fun-\d+-/, "-fun-")

  defp normalize_text(s) do
    s
    |> String.replace(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, "<uuid>")
    |> String.replace(~r/#(PID|Reference|Port)<[\d.]+>/, "<\\1>")
    |> String.replace(~r/\d+/, "<n>")
  end

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> binary_part(0, 12) |> Base.encode16(case: :lower)

  defp label do
    case :proc_lib.get_label(self()) do
      :undefined -> nil
      l -> inspect(l)
    end
  end

  defp short(nil), do: nil
  defp short(t), do: inspect(t, limit: 20, printable_limit: 500)

  def text({:string, s}), do: IO.chardata_to_string(s)
  def text({:report, r}), do: short(r)
  def text({f, a}) when is_list(a), do: f |> :io_lib.format(a) |> IO.chardata_to_string()
  def text(s) when is_binary(s), do: s
  def text(other), do: short(other)
end
