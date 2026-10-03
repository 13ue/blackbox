defmodule Spike.Load do
  @moduledoc "Paced load, latency probe and memory sampler for the flood tests."
  @log "../../logs/08-flood.log"

  def log(line) do
    IO.puts(line)
    File.write!(@log, line <> "\n", [:append])
  end

  # Runs `procs` producers for `secs`, together `rate` calls/s, in 10 ms slices. Returns sent.
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
    next = t0 + (div(sent, n) + 1) * 10
    wait = next - System.monotonic_time(:millisecond)
    if wait > 0, do: Process.sleep(wait)
    produce(p, n, t0, slices - 1, fun, sent + n)
  end

  # GenServer.call round trip every ms while `during` runs; returns {p50, p99, max} in µs.
  def probe(during) do
    {:ok, echo} = Agent.start_link(fn -> 0 end)
    me = self()
    stop = :atomics.new(1, [])
    prober = spawn_link(fn -> send(me, {:lat, probe_loop(echo, stop, [])}) end)
    result = during.()
    :atomics.put(stop, 1, 1)
    lats = receive do {:lat, l} -> Enum.sort(l) end
    _ = prober
    {pct(lats, 0.5), pct(lats, 0.99), List.last(lats), result}
  end

  defp probe_loop(echo, stop, acc) do
    if :atomics.get(stop, 1) == 1 do
      acc
    else
      {us, _} = :timer.tc(fn -> Agent.get(echo, & &1) end)
      Process.sleep(1)
      probe_loop(echo, stop, [us | acc])
    end
  end

  def pct(sorted, p), do: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))

  # Samples buffer memory + total VM memory every 50 ms while `during` runs.
  def sample_memory(during) do
    stop = :atomics.new(1, [])
    me = self()
    spawn_link(fn -> send(me, {:mem, mem_loop(stop, {0, 0, 0})}) end)
    result = during.()
    :atomics.put(stop, 1, 1)
    receive do {:mem, m} -> {m, result} end
  end

  defp mem_loop(stop, {bmax, tmax, qmax} = acc) do
    if :atomics.get(stop, 1) == 1 do
      acc
    else
      b = Process.whereis(Spike.Buffer)
      {:memory, bm} = Process.info(b, :memory)
      {:message_queue_len, q} = Process.info(b, :message_queue_len)
      Process.sleep(50)
      mem_loop(stop, {max(bmax, bm), max(tmax, :erlang.memory(:total)), max(qmax, q)})
    end
  end
end
