alias BeforeLab.Ring
Ring.Ets.new()
defmodule H do
  def pdict(e, m, _meta, _), do: Ring.Pdict.add({System.monotonic_time(), e, m})
  def ets(e, m, _meta, _), do: Ring.Ets.add({System.monotonic_time(), e, m})
  def noop(_, _, _, _), do: :ok
end
opts = [warmup: 1, time: 3, memory_time: 1, print: [configuration: false]]
meas = %{duration: 1234, total_time: 1500}
meta = %{repo: :repo, query: "SELECT 1", params: [1, 2, 3], source: "users"}
Benchee.run(%{"execute, 0 handlers" => fn -> :telemetry.execute([:none, :here], meas, meta) end}, opts)
:telemetry.attach(:noop, [:ev, :noop], &H.noop/4, nil)
:telemetry.attach(:pd, [:ev, :pdict], &H.pdict/4, nil)
:telemetry.attach(:et, [:ev, :ets], &H.ets/4, nil)
Benchee.run(%{
  "execute, 1 noop handler" => fn -> :telemetry.execute([:ev, :noop], meas, meta) end,
  "execute, 1 handler -> pdict ring" => fn -> :telemetry.execute([:ev, :pdict], meas, meta) end,
  "execute, 1 handler -> ETS ring" => fn -> :telemetry.execute([:ev, :ets], meas, meta) end
}, opts)
crumb = {System.monotonic_time(), [:ev, :pdict], meas}
IO.puts("telemetry crumb {t, event, measurements}: #{:erts_debug.flat_size(crumb) * 8} heap bytes")
