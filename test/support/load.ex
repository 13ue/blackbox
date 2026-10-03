defmodule Blackbox.Load do
  @moduledoc "Paced load and a latency probe for the flood tests (from lab 08)."

  # `procs` producers for `secs`, together `rate` calls/s, in 10 ms slices. Returns sent.
  def paced(rate, secs, fun, procs \\ 10) do
    per_slice = div(rate, procs * 100)
    t0 = System.monotonic_time(:millisecond)

    1..procs
    |> Enum.map(fn p -> Task.async(fn -> produce(p, per_slice, t0, secs * 100, fun, 0) end) end)
    |> Enum.map(&Task.await(&1, :infinity))
    |> Enum.sum()
  end

  defp produce(_, _, _, 0, _, sent), do: sent

  defp produce(p, n, t0, slices, fun, sent) do
    for i <- 1..n, do: fun.(p, i)
    wait = t0 + (div(sent, n) + 1) * 10 - System.monotonic_time(:millisecond)
    if wait > 0, do: Process.sleep(wait)
    produce(p, n, t0, slices - 1, fun, sent + n)
  end

  # A writer that only counts: {occurrences counted, issues, samples}.
  def counter do
    ref = :atomics.new(3, [])

    writer = fn batch ->
      for i <- batch, do: :atomics.add(ref, 1, i.count)
      :atomics.add(ref, 2, length(batch))
      :atomics.add(ref, 3, Enum.sum(for i <- batch, do: length(i.samples)))
      :ok
    end

    {writer, fn -> {:atomics.get(ref, 1), :atomics.get(ref, 2), :atomics.get(ref, 3)} end}
  end

  def settle(n \\ 20),
    do:
      Enum.each(1..n, fn _ ->
        Blackbox.Buffer.flush()
        Process.sleep(100)
      end)
end
