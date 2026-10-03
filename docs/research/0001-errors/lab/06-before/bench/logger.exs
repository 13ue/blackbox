require Logger
alias BeforeLab.{Ring, CrumbHandler}
:logger.update_handler_config(:default, :level, :info)
Ring.Ets.new()
{:ok, _} = Ring.Server.start_link()
defmodule EtsHandler do
  def log(%{level: l, msg: m, meta: meta}, _), do: Ring.Ets.add({meta[:time], l, m})
end

opts = [warmup: 1, time: 3, memory_time: 1, print: [configuration: false]]
IO.puts("### primary :info (debug off)")
:logger.set_primary_config(:level, :info)
Benchee.run(%{"Logger.debug off" => fn -> Logger.debug("step", user: 1) end}, opts)

:logger.set_primary_config(:level, :debug)
IO.puts("### primary :debug, only console handler at :info")
Benchee.run(%{"Logger.debug, no crumb handler" => fn -> Logger.debug("step", user: 1) end}, opts)

:logger.add_handler(:crumbs, CrumbHandler, %{level: :all})
IO.puts("### primary :debug + pdict crumb handler")
Benchee.run(%{"Logger.debug -> pdict ring" => fn -> Logger.debug("step", user: 1) end}, opts)
:logger.remove_handler(:crumbs)

:logger.add_handler(:crumbs_ets, EtsHandler, %{level: :all})
IO.puts("### primary :debug + ETS crumb handler")
Benchee.run(%{"Logger.debug -> ETS ring" => fn -> Logger.debug("step", user: 1) end}, opts)
:logger.remove_handler(:crumbs_ets)

crumb = {System.os_time(:microsecond), :debug, "step"}
IO.puts("### raw ring writes, 1 process")
Benchee.run(%{
  "Ring.Pdict.add" => fn -> Ring.Pdict.add(crumb) end,
  "Ring.Ets.add" => fn -> Ring.Ets.add(crumb) end,
  "Ring.Server.add (cast)" => fn -> Ring.Server.add(crumb) end
}, opts)
IO.puts("### raw ring writes, 8 parallel processes")
Benchee.run(%{
  "Ring.Pdict.add" => fn -> Ring.Pdict.add(crumb) end,
  "Ring.Ets.add" => fn -> Ring.Ets.add(crumb) end,
  "Ring.Server.add (cast)" => fn -> Ring.Server.add(crumb) end
}, Keyword.put(opts, :parallel, 8))
Process.sleep(500)
IO.puts("server mailbox after parallel run: #{inspect(Process.info(Process.whereis(Ring.Server), :message_queue_len))}")

# bytes
:logger.add_handler(:grab, BeforeLab.Capture, %{level: :all, config: %{to: self()}})
Logger.debug("step", user: 1)
receive do
  {:logged, ev, _, _} ->
    IO.puts("full logger event: #{:erts_debug.flat_size(ev) * 8} heap bytes, #{:erlang.external_size(ev)} external bytes")
end
IO.puts("compact crumb {time, level, msg}: #{:erts_debug.flat_size(crumb) * 8} heap bytes (+ binary 4 bytes off-heap)")
Ring.Pdict.clear()
for i <- 1..50, do: Ring.Pdict.add({System.os_time(:microsecond), :debug, "step #{i} with some text"})
IO.puts("pdict ring of 50 crumbs: #{:erts_debug.flat_size(Process.get(Ring.Pdict.key())) * 8} heap bytes")
IO.puts("ETS table after runs: #{Ring.Ets.size()} rows, #{Ring.Ets.memory_bytes()} bytes")
