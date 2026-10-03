defmodule Blackbox.Scrub do
  @moduledoc """
  Removes secrets before anything is formatted, stored or spooled.

      config :blackbox,
        # added to Phoenix's :filter_parameters and the defaults below; a key
        # matches when its name contains one of these, case-insensitively
        scrub_keys: ["board_key"],
        # regexes over paths and text; group 1 is replaced, or the whole match
        # (a segment starting with ":" is a route template, kept here)
        scrub_patterns: ["/b/([^:/?#\\\\s][^/?#\\\\s]*)"]

  Terms: map and keyword values under a matching key, the fields of
  exceptions that carry values (`KeyError`, `MatchError`, `CaseClauseError`,
  `WithClauseError`, `BadMapError`, `FunctionClauseError` arguments,
  `Postgrex.Error` details), and the message of a call inside an exit reason
  (only its tag stays). Text: `key=value`, `key: "value"`, the patterns, and
  a 1 KB cap on messages.

  Positional content (`{:say, from, text}`) has no key to match: a
  GenServer's `format_status/1` sees `state`, `message` and `log` before OTP
  reports them, and is the place to summarise them.
  """

  @filtered "[Filtered]"
  @default_keys ~w(password passwd token secret authorization cookie api_key apikey key)
  @max_depth 20
  @max_text 1_024

  def filtered, do: @filtered

  ## Config, compiled once

  def config do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> compile()
      c -> c
    end
  end

  @doc false
  def compile do
    keys =
      (@default_keys ++ phoenix_keys() ++ Application.get_env(:blackbox, :scrub_keys, []))
      |> Enum.map(&(&1 |> to_string() |> String.downcase()))
      |> Enum.uniq()

    alt = Enum.map_join(keys, "|", &Regex.escape/1)

    c = %{
      keys: keys,
      # A pre-check far cheaper than the regex: most lines name no key at all.
      # ponytail: lower, Capitalized and UPPER only; a mixed-case "ToKeN=" skips the key regex.
      needles:
        :binary.compile_pattern(
          Enum.flat_map(keys, &[&1, String.capitalize(&1), String.upcase(&1)])
        ),
      # key=value (query strings, logfmt), key: "value" and key: value (inspect), "key" => "value"
      text:
        Regex.compile!(
          ~S/([\w-]*(?:/ <>
            alt <>
            ~S/)[\w-]*"?)(\s*(?:=>|=)\s*|:\s*)(?!"?\[Filtered\])("[^"]*"|'[^']*'|[^\s&,;}\])"']+)/,
          "i"
        ),
      patterns:
        for source <- Application.get_env(:blackbox, :scrub_patterns, []) do
          # Regex.replace calls the replacement with one argument per group.
          {Regex.compile!(source), Regex.match?(~r/(?<!\\)\((?!\?)/, source)}
        end
    }

    :persistent_term.put(__MODULE__, c)
    c
  end

  defp phoenix_keys do
    case Application.get_env(:phoenix, :filter_parameters, []) do
      keys when is_list(keys) -> keys
      _ -> []
    end
  end

  ## Text

  def text(s) when is_binary(s) do
    c = config()

    s =
      if :binary.match(s, c.needles) == :nomatch,
        do: s,
        else: Regex.replace(c.text, s, fn _, k, sep, _ -> k <> sep <> @filtered end)

    Enum.reduce(c.patterns, s, fn
      {re, true}, acc ->
        Regex.replace(re, acc, fn whole, group -> String.replace(whole, group, @filtered) end)

      {re, false}, acc ->
        Regex.replace(re, acc, @filtered)
    end)
  end

  def text(other), do: other

  def message(s) when is_binary(s) and byte_size(s) > @max_text,
    do: text(binary_part(s, 0, @max_text)) <> "..."

  def message(s), do: text(s)

  ## Terms

  def term(t), do: walk(t, 0)

  @doc "A `:sys` debug log, with every message reduced to its tag (06-35)."
  def sys_log(log) when is_list(log) do
    for entry <- log do
      case entry do
        {:in, {:"$gen_call", _from, msg}} -> {:in, :call, tag(msg)}
        {:in, {:"$gen_cast", msg}} -> {:in, :cast, tag(msg)}
        {:in, msg} -> {:in, tag(msg)}
        {:in, msg, from} -> {:in, tag(msg), from}
        {:out, msg, to} -> {:out, tag(msg), to}
        {:out, msg, to, _state} -> {:out, tag(msg), to}
        {kind, state} when kind in [:noreply, :postpone] -> {kind, walk(state, 1)}
        other -> tag(other)
      end
    end
  end

  def sys_log(other), do: walk(other, 0)

  defp walk(_, depth) when depth > @max_depth, do: "[Deep]"

  defp walk(%{__exception__: true} = e, depth), do: exception(e, depth)

  defp walk(%{} = m, depth) do
    :maps.map(
      fn
        :__struct__, s -> s
        k, v -> if secret?(k), do: @filtered, else: walk(v, depth + 1)
      end,
      m
    )
  end

  defp walk([_ | _] = list, depth) do
    if List.ascii_printable?(list, 1_024),
      do: text(List.to_string(list)) |> String.to_charlist(),
      else: walk_list(list, depth)
  end

  # A stack frame nested in a term (an exit reason, a `{:function_clause, stack}`)
  # carries the call's arguments; only the arity stays.
  defp walk({m, f, args, loc}, _)
       when is_atom(m) and is_atom(f) and is_list(args) and is_list(loc),
       do: {m, f, length(args), loc}

  defp walk({mod, :call, [server, msg | rest]}, depth)
       when mod in [GenServer, :gen_server, :gen, :gen_statem],
       do: {mod, :call, [server, tag(msg) | walk(rest, depth + 1)]}

  defp walk({k, v}, depth) when is_atom(k) or is_binary(k) do
    if secret?(k), do: {k, @filtered}, else: {k, walk(v, depth + 1)}
  end

  defp walk(t, depth) when is_tuple(t),
    do: t |> Tuple.to_list() |> walk_list(depth) |> List.to_tuple()

  defp walk(s, _) when is_binary(s), do: text(s)
  defp walk(other, _), do: other

  # Improper lists are kept as they are.
  defp walk_list(list, depth) do
    if :erlang.length(list) >= 0, do: Enum.map(list, &walk(&1, depth + 1)), else: list
  rescue
    ArgumentError -> list
  end

  # {:apply, ops, ...} -> {:apply, ...}: a call's message is positional, so no key scrubber sees it.
  defp tag(msg) when is_tuple(msg) and tuple_size(msg) > 0 and is_atom(elem(msg, 0)),
    do: {elem(msg, 0), :...}

  defp tag(msg) when is_atom(msg), do: msg
  defp tag(_), do: @filtered

  defp secret?(k) when is_atom(k), do: secret?(Atom.to_string(k))

  defp secret?(k) when is_binary(k) do
    k = String.downcase(k)
    Enum.any?(config().keys, &String.contains?(k, &1))
  end

  defp secret?(_), do: false

  ## Exceptions whose fields carry values

  @shaped [
    KeyError,
    MatchError,
    CaseClauseError,
    WithClauseError,
    BadMapError,
    BadBooleanError,
    TryClauseError,
    BadStructError
  ]

  # KeyError's `key` field is the key that was missing, not a secret by its
  # name: an atom or number stays, a string (it could be a token) does not.
  defp exception(%KeyError{} = e, depth) do
    key = if is_atom(e.key) or is_number(e.key), do: e.key, else: @filtered
    %{walk_fields(%{e | term: shape(e.term)}, depth) | key: key}
  end

  defp exception(%{__struct__: s} = e, depth) when s in @shaped do
    e = if Map.has_key?(e, :term), do: %{e | term: shape(e.term)}, else: e
    walk_fields(e, depth)
  end

  defp exception(%FunctionClauseError{} = e, _), do: %{e | args: nil}

  defp exception(%{__struct__: Postgrex.Error, postgres: %{} = pg} = e, depth) do
    walk_fields(%{e | postgres: Map.drop(pg, [:detail, :hint, :where])}, depth)
  end

  defp exception(e, depth), do: walk_fields(e, depth)

  defp walk_fields(e, depth) do
    :maps.map(
      fn
        k, v when k in [:__struct__, :__exception__] -> v
        k, v -> if secret?(k), do: @filtered, else: walk(v, depth + 1)
      end,
      e
    )
  end

  # A term inside an error is kept as its shape: type, and keys for maps.
  def shape(%{__struct__: _} = m),
    do: :maps.map(fn k, v -> if k in [:__struct__, :__exception__], do: v, else: @filtered end, m)

  def shape(%{} = m), do: Map.new(Map.keys(m), &{&1, @filtered})

  def shape(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)),
    do: {elem(t, 0), :...}

  def shape(t) when is_atom(t) or is_number(t), do: t
  def shape(_), do: @filtered
end
