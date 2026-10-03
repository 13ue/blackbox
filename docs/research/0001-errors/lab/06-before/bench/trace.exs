defmodule W do
  def step(x), do: x + 1
  def calls(n), do: (for i <- 1..n, do: step(i)); :ok
  def recv(0), do: :ok
  def recv(n) do
    receive do
      _ -> recv(n - 1)
    end
  end
end
defmodule Sink do
  def loop(n) do
    receive do
      _ -> loop(n + 1)
    end
  end
end
n = 1_000_000
run_in = fn fun ->
  me = self()
  pid = spawn(fn ->
    receive do
      :go -> send(me, {:t, elem(:timer.tc(fun), 0)})
    end
  end)
  go = fn ->
    send(pid, :go)
    receive do
      {:t, t} -> t
    end
  end
  {pid, go}
end
med = fn mk -> runs = for _ <- 1..5, do: mk.(); Enum.at(Enum.sort(runs), 2) end

base = med.(fn -> {_p, go} = run_in.(fn -> W.calls(n) end); go.() end)
IO.puts("local call, untraced: #{Float.round(base * 1000 / n, 1)} ns/call")

traced = med.(fn ->
  sink = spawn(fn -> Sink.loop(0) end)
  s = :trace.session_create(:bench, sink, [])
  {p, go} = run_in.(fn -> W.calls(n) end)
  :trace.process(s, p, true, [:call])
  :trace.function(s, {W, :step, 1}, true, [:local])
  t = go.()
  :trace.session_destroy(s); Process.exit(sink, :kill); t
end)
IO.puts("local call, call-traced by a session (tracer = draining process): #{Float.round(traced * 1000 / n, 1)} ns/call")

other = med.(fn ->
  sink = spawn(fn -> Sink.loop(0) end)
  s = :trace.session_create(:bench2, sink, [])
  :trace.function(s, {W, :step, 1}, true, [:local])
  # traced function, but THIS process has no call flag
  {_p, go} = run_in.(fn -> W.calls(n) end)
  t = go.()
  :trace.session_destroy(s); Process.exit(sink, :kill); t
end)
IO.puts("local call, function has a trace pattern but the process is not traced: #{Float.round(other * 1000 / n, 1)} ns/call")

m = 200_000
rbase = med.(fn -> {p, go} = run_in.(fn -> W.recv(m) end); for i <- 1..m, do: send(p, i); go.() end)
IO.puts("receive #{m} queued msgs, untraced: #{Float.round(rbase * 1000 / m, 1)} ns/msg")
rtr = med.(fn ->
  sink = spawn(fn -> Sink.loop(0) end)
  s = :trace.session_create(:bench3, sink, [])
  {p, go} = run_in.(fn -> W.recv(m) end)
  :trace.process(s, p, true, [:receive])
  for i <- 1..m, do: send(p, i)
  t = go.()
  :trace.session_destroy(s); Process.exit(sink, :kill); t
end)
IO.puts("receive, receive-traced by a session: #{Float.round(rtr * 1000 / m, 1)} ns/msg (the tracing cost lands at send time for the sender too, not measured here)")
ev = {:trace, self(), :receive, {:work, 1}}
IO.puts("one trace message {:trace, pid, :receive, {:work, 1}}: #{:erts_debug.flat_size(ev) * 8} heap bytes in the tracer")
# receive trace events are generated when the message is ENQUEUED, so the sender pays: measure send time
sendt = fn traced? ->
  runs = for _ <- 1..5 do
    sink = spawn(fn -> Sink.loop(0) end)
    s = :trace.session_create(:bench4, sink, [])
    p = spawn(fn -> Process.sleep(:infinity) end)
    if traced?, do: :trace.process(s, p, true, [:receive])
    {t, _} = :timer.tc(fn -> for i <- 1..m, do: send(p, i) end)
    :trace.session_destroy(s); Process.exit(sink, :kill); Process.exit(p, :kill); t
  end
  Enum.at(Enum.sort(runs), 2) * 1000 / m
end
IO.puts("send to an untraced process: #{Float.round(sendt.(false), 1)} ns/msg")
IO.puts("send to a receive-traced process: #{Float.round(sendt.(true), 1)} ns/msg")
