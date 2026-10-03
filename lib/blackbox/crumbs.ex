defmodule Blackbox.Crumbs do
  @moduledoc false
  # A ring of what happened in this process, in its own dictionary: no shared
  # store (one GenServer drowned, an ETS ring leaked; lab 06). `{count, list}`,
  # newest first, trimmed back to @cap at 2 * @cap.

  @cap 50
  @bytes 200
  @key :blackbox_crumbs

  def cap, do: @cap
  def key, do: @key

  def add(level, msg, data \\ %{}) do
    {n, list} = Process.get(@key, {0, []})
    {n, list} = if n >= 2 * @cap, do: {@cap, Enum.take(list, @cap)}, else: {n, list}

    entry =
      {System.system_time(:microsecond), level, small(msg), small(data) |> Blackbox.Scrub.term()}

    Process.put(@key, {n + 1, [entry | list]})
    :ok
  end

  def own, do: raw(Process.get(@key))

  def reset, do: Process.delete(@key) && :ok

  def of(pid) when is_pid(pid) do
    case :erlang.process_info(pid, {:dictionary, @key}) do
      {{:dictionary, @key}, v} -> raw(v)
      _ -> []
    end
  end

  def of(_), do: []

  # Oldest first, at most @cap.
  defp raw({_, list}), do: list |> Enum.take(@cap) |> Enum.reverse()
  defp raw(_), do: []

  # Text is scrubbed here, so the dictionary (seen by Process.info/2,
  # observer and crash reports) never holds a secret. A slice of a big binary
  # keeps all of it alive (10-10), so binaries are copied and capped.
  # ponytail: containers one level deep; a binary nested two levels down stays referenced.
  defp small({:string, s}) when is_binary(s), do: {:string, s |> cut() |> Blackbox.Scrub.text()}

  defp small({:string, s}),
    do: {:string, s |> IO.chardata_to_string() |> cut() |> Blackbox.Scrub.text()}

  defp small({:report, r}) when is_map(r),
    do: {:report, r |> Map.new(fn {k, v} -> {k, cut(v)} end) |> Blackbox.Scrub.term()}

  defp small({f, a}) when is_list(a) do
    {:string, f |> :io_lib.format(a) |> IO.chardata_to_string() |> cut() |> Blackbox.Scrub.text()}
  rescue
    _ -> {:string, "(unprintable)"}
  end

  defp small(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, cut(v)} end)
  defp small(other), do: cut(other)

  defp cut(s) when is_binary(s) and byte_size(s) > @bytes,
    do: :binary.copy(binary_part(s, 0, @bytes))

  defp cut(s) when is_binary(s), do: :binary.copy(s)
  defp cut(other), do: other
end
