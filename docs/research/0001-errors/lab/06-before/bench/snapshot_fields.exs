m = 20_000
med = fn f -> f.(); runs = for _ <- 1..5, do: elem(:timer.tc(fn -> for _ <- 1..m, do: f.() end), 0); Enum.at(Enum.sort(runs), 2) / m end
for {name, f} <- [
  {":erlang.memory()", fn -> :erlang.memory() end},
  {":erlang.memory(:total)", fn -> :erlang.memory(:total) end},
  {"statistics(:total_run_queue_lengths)", fn -> :erlang.statistics(:total_run_queue_lengths) end},
  {"statistics(:run_queue)", fn -> :erlang.statistics(:run_queue) end},
  {"system_info(:process_count)", fn -> :erlang.system_info(:process_count) end},
  {"length(:ets.all())", fn -> length(:ets.all()) end},
  {"statistics(:reductions)", fn -> :erlang.statistics(:reductions) end},
  {"statistics(:io)", fn -> :erlang.statistics(:io) end},
  {"Process.info(self(), :current_stacktrace)", fn -> Process.info(self(), :current_stacktrace) end},
  {"Process.info(self(), [:message_queue_len, :memory, :reductions])", fn -> Process.info(self(), [:message_queue_len, :memory, :reductions]) end},
  {"Process.info(self(), :links)", fn -> Process.info(self(), :links) end}
] do
  IO.puts("#{name}: #{Float.round(med.(f), 3)} µs")
end
