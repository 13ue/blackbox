defmodule BeforeLab.Capture do
  @moduledoc "Logger handler for tests: forwards each event with the pid it runs in and the pdict ring seen there."
  def log(event, %{config: %{to: to}}) do
    send(to, {:logged, event, self(), BeforeLab.Ring.Pdict.read()})
  end

  def attach(id, level, to) do
    :ok = :logger.add_handler(id, __MODULE__, %{level: level, config: %{to: to}})
  end
end

defmodule BeforeLab.CrumbHandler do
  @moduledoc "Logger handler that turns every event (any level) into a compact breadcrumb in the caller's pdict ring."
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    BeforeLab.Ring.Pdict.add({meta[:time], level, compact(msg)})
  end

  # keep the unformatted message; formatting is deferred until a crash needs it
  defp compact({:string, s}), do: s
  defp compact(other), do: other
end

defmodule BeforeLab.Raiser do
  @moduledoc "Logger handler that always raises (to prove OTP removes it)."
  def log(_event, _config), do: raise("handler bug")
end
