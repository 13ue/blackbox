require Logger
{:ok, _} = Spike.DownRepo.start_link()
Spike.Buffer.set_writer(Spike.Store.writer(Spike.DownRepo))
for n <- 1..5 do
  Logger.error("while db down")
  Process.sleep(400)
  s = :sys.get_state(Spike.Buffer)
  IO.puts("t=#{n*400}ms task?=#{s.task != nil} pending=#{map_size(s.pending)} backoff=#{s.backoff} stats=#{inspect Spike.stats()}")
end
IO.inspect(:timer.tc(fn -> Spike.Store.write(Spike.DownRepo, [%{fingerprint: "x", type: "t", count: 1, first_at: 1, last_at: 1, samples: [%{message: "m"}]}]) end), limit: 6)
