:logger.remove_handler(:default)
defmodule P do
  def log(ev, %{config: %{to: to}}), do: send(to, {:ev, ev})
end
:logger.add_handler(:probe, P, %{level: :all, config: %{to: self()}})
r = fn tag -> receive do {:ev, e} -> IO.puts("#{tag}: reached #{inspect(e.msg, limit: 5)}") after 300 -> IO.puts("#{tag}: nothing") end end
:logger.log(:error, %{label: :poison}, %{}); r.("report with label, no crash_reason")
:logger.log(:error, %{foo: 1}, %{}); r.("report without label")
:logger.log(:error, %{foo: 1}, %{crash_reason: {:x, :bad}}); r.("report + bogus crash_reason")
require Logger
Logger.error("poison", crash_reason: {:x, :bad}); r.("Logger.error + bogus crash_reason")
IO.inspect(Logger.Translator.translate(:error, :error, :report, {:logger, %{label: :poison}}), label: "translate")
