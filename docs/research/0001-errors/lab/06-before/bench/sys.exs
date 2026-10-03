defmodule Echo do
  use GenServer
  def init(s), do: {:ok, s}
  def handle_call(m, _f, s), do: {:reply, m, s}
end
n = 500_000
med = fn f -> f.(); runs = for _ <- 1..5, do: elem(:timer.tc(f), 0); Enum.at(Enum.sort(runs), 2) end
{:ok, plain} = GenServer.start(Echo, nil)
{:ok, logged} = GenServer.start(Echo, nil, debug: [log: 10])
{:ok, logged50} = GenServer.start(Echo, nil, debug: [log: 50])
for {name, pid} <- [{"call, no debug", plain}, {"call, debug log 10", logged}, {"call, debug log 50", logged50}] do
  t = med.(fn -> for _ <- 1..n, do: GenServer.call(pid, :hi) end)
  IO.puts("#{name}: #{Float.round(t * 1000 / n, 1)} ns/call")
end
{:dictionary, _} = Process.info(logged, :dictionary)
IO.puts(":sys log 10 entries in server state: #{:erts_debug.flat_size(:sys.get_status(logged)) * 8} bytes of get_status (whole status)")

snapshot = fn ->
  %{
    memory: :erlang.memory(),
    run_queue: :erlang.statistics(:total_run_queue_lengths),
    process_count: :erlang.system_info(:process_count),
    port_count: :erlang.system_info(:port_count),
    ets_count: length(:ets.all()),
    reductions: elem(:erlang.statistics(:reductions), 0),
    io: :erlang.statistics(:io),
    uptime_ms: elem(:erlang.statistics(:wall_clock), 0),
    schedulers_online: :erlang.system_info(:schedulers_online)
  }
end
snap_cheap = fn ->
  %{
    memory_total: :erlang.memory(:total),
    run_queue: :erlang.statistics(:total_run_queue_lengths),
    process_count: :erlang.system_info(:process_count)
  }
end
proc_snap = fn -> Process.info(self(), [:message_queue_len, :memory, :heap_size, :reductions, :current_stacktrace, :status, :links, :monitors]) end
m = 20_000
for {name, f} <- [{"system snapshot (9 fields, incl. ets.all)", snapshot}, {"system snapshot cheap (3 fields)", snap_cheap}, {"Process.info(self(), 8 items)", proc_snap}] do
  t = med.(fn -> for _ <- 1..m, do: f.() end)
  IO.puts("#{name}: #{Float.round(t / m, 2)} µs, #{:erts_debug.flat_size(f.()) * 8} heap bytes")
end
# reading another process's pdict ring (Task crash -> parent's ring)
for i <- 1..50, do: BeforeLab.Ring.Pdict.add({System.os_time(), :debug, "step #{i} with some text"})
me = self()
t = med.(fn -> for _ <- 1..m, do: BeforeLab.Ring.Pdict.read(me) end)
IO.puts("Ring.Pdict.read(other_pid) with 50 crumbs (Process.info :dictionary): #{Float.round(t / m, 2)} µs")
IO.puts(":ets.all count now: #{length(:ets.all())}, process_count #{:erlang.system_info(:process_count)}")
