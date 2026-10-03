:logger.remove_handler(:default)
defmodule P do
  def log(ev, %{config: %{to: to}}), do: send(to, {:ev, ev})
end
:logger.add_handler(:probe, P, %{level: :all, config: %{to: self()}})
:logger.log(:error, %{label: :poison}, %{crash_reason: {:not_a_stacktrace, :bad}})
receive do {:ev, e} -> IO.inspect(e, label: "poison reached handler") after 300 -> IO.puts("poison: nothing") end
IO.inspect(Keyword.keys(:logger.get_primary_config().filters), label: "filters after")
IO.inspect(Logger.configure(handle_sasl_reports: true), label: "configure sasl")
IO.inspect(:logger.get_primary_config().filters[:logger_translator], label: "translator after configure")
:proc_lib.spawn(fn -> raise "pl" end)
receive do {:ev, e} -> IO.inspect(e.meta |> Map.take([:domain, :crash_reason]), label: "proc_lib ev") after 300 -> IO.puts("proc_lib: nothing") end
