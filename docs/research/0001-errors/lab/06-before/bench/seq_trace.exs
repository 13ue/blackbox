defmodule Echo do
  use GenServer
  def init(s), do: {:ok, s}
  def handle_call(m, _f, s), do: {:reply, m, s}
end
{:ok, srv} = GenServer.start(Echo, nil)
n = 1_000_000
loop = fn f -> for _ <- 1..n, do: f.() end
measure = fn name, label ->
  if label, do: :seq_trace.set_token(:label, label), else: :seq_trace.set_token([])
  loop.(fn -> GenServer.call(srv, :hi) end)
  runs = for _ <- 1..5, do: elem(:timer.tc(fn -> loop.(fn -> GenServer.call(srv, :hi) end) end), 0) * 1000 / n
  IO.puts("#{name}: median of 5 runs #{Enum.at(Enum.sort(runs), 2) |> Float.round(1)} ns/call (runs #{inspect(Enum.map(runs, &round/1))})")
end
measure.("GenServer.call, no label", nil)
measure.("GenServer.call, label \"req-0123456789\"", "req-0123456789")
measure.("GenServer.call, label 1 KB map", Map.new(1..40, &{&1, "value-#{&1}"}))
:seq_trace.set_token(:label, "x")
{t, _} = :timer.tc(fn -> for _ <- 1..n, do: :seq_trace.set_token(:label, "req-0123456789") end)
IO.puts("set_token(:label, id): #{Float.round(t * 1000 / n, 1)} ns")
{t, _} = :timer.tc(fn -> for _ <- 1..n, do: :seq_trace.get_token(:label) end)
IO.puts("get_token(:label): #{Float.round(t * 1000 / n, 1)} ns")
