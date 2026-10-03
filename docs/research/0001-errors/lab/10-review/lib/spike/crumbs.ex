defmodule Spike.Crumbs do
  @moduledoc "Per-process ring buffer of breadcrumbs in the process dictionary."
  @cap 20
  @key :spike_crumbs

  # Stores the raw message (no formatting): the cost is paid only when a crash reads it.
  def add(level, msg) do
    {n, list} = Process.get(@key, {0, []})
    {n, list} = if n >= 2 * @cap, do: {@cap, Enum.take(list, @cap)}, else: {n, list}
    Process.put(@key, {n + 1, [{System.system_time(:millisecond), level, msg} | list]})
    :ok
  end

  # Raw entries; format/1 turns them into maps later, outside the failing process.
  def own, do: raw(Process.get(@key))

  def of(pid) when is_pid(pid) do
    case :erlang.process_info(pid, {:dictionary, @key}) do
      {{:dictionary, @key}, v} -> raw(v)
      _ -> []
    end
  end

  def of(_), do: []

  defp raw({_, list}), do: list |> Enum.take(@cap) |> Enum.reverse()
  defp raw(_), do: []

  def format(list), do: for({at, level, msg} <- list, do: %{at: at, level: level, message: Spike.Event.text(msg)})
end
