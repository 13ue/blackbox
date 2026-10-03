require Logger
:logger.remove_handler(:default)
Spike.Buffer.set_writer(fn _ -> Process.sleep(:infinity) end)
Logger.error("survives a hung writer")
Spike.Buffer.flush()
IO.inspect(:sys.get_state(Spike.Buffer) |> Map.drop([:writer]), label: "after flush", limit: 8)
Process.sleep(700)
IO.inspect(:sys.get_state(Spike.Buffer) |> Map.drop([:writer]), label: "after 700ms", limit: 8)
IO.inspect(Spike.stats())
