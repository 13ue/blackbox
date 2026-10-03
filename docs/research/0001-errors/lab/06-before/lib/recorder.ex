defmodule BeforeLab.Recorder do
  @moduledoc "A trace-session tracer that keeps the last N trace messages per traced pid in its own state."
  use GenServer
  @max 20

  def start(name), do: GenServer.start(__MODULE__, name)
  def dump(rec, pid), do: GenServer.call(rec, {:dump, pid})
  def session(rec), do: GenServer.call(rec, :session)

  @impl true
  def init(name), do: {:ok, %{session: :trace.session_create(name, self(), []), rings: %{}}}

  @impl true
  def handle_call(:session, _f, s), do: {:reply, s.session, s}
  def handle_call({:dump, pid}, _f, s), do: {:reply, Enum.reverse(Map.get(s.rings, pid, [])), s}

  @impl true
  def handle_info(msg, s) when elem(msg, 0) in [:trace, :trace_ts] do
    pid = elem(msg, 1)
    {:noreply, %{s | rings: Map.update(s.rings, pid, [msg], &Enum.take([msg | &1], @max))}}
  end

  def handle_info(_, s), do: {:noreply, s}
end
