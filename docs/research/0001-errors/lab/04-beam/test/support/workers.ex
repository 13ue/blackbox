defmodule BeamLab.Srv do
  use GenServer
  import BeamLab.Case, only: [crash: 1]

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  def init({:label, l}), do: (Process.set_label(l); {:ok, %{}})
  def init({:trap, s}), do: (Process.flag(:trap_exit, true); {:ok, s})
  def init(:raise), do: crash(:raise)
  def init(s), do: {:ok, s}

  def handle_call({:do, k}, _from, _s), do: crash(k)
  def handle_call({:stop, r}, _from, s), do: {:stop, r, :ok, s}
  def handle_call(:sleep, _from, s), do: (Process.sleep(300); {:reply, :ok, s})
  def handle_call(:ping, _from, s), do: {:reply, :pong, s}
  def handle_cast({:do, k}, _s), do: crash(k)
  def handle_cast({:stop, r}, s), do: {:stop, r, s}
  def handle_info({:do, k}, _s), do: crash(k)

  def terminate(_r, %{raise_in_terminate: true}), do: raise("terminate boom")
  def terminate(_r, _s), do: :ok
end

defmodule BeamLab.Statem do
  @behaviour :gen_statem
  import BeamLab.Case, only: [crash: 1]
  def callback_mode, do: :handle_event_function
  def init(d), do: {:ok, :idle, d}
  def handle_event({:call, _from}, {:do, k}, _state, _data), do: crash(k)
end

defmodule BeamLab.Deep do
  def down(0), do: raise("deep")
  def down(n), do: [down(n - 1)]
  def a(0), do: raise("deep")
  def a(n), do: 1 + b(n - 1)
  def b(n), do: 1 + a(n)
end

defmodule BeamLab.Sasl do
  @moduledoc "Flip Elixir's primary translator filter to let [:otp, :sasl] reports through (handle_sasl_reports: true)."
  def set(on?) do
    %{filters: fs} = :logger.get_primary_config()
    {fun, cfg} = fs[:logger_translator]
    :ok = :logger.remove_primary_filter(:logger_translator)
    :ok = :logger.add_primary_filter(:logger_translator, {fun, %{cfg | sasl: on?}})
  end
end

defmodule BeamLab.LabApp do
  use Application
  def start(_t, _a), do: Supervisor.start_link([{BeamLab.Srv, %{}}], strategy: :one_for_one, name: BeamLab.LabApp.Sup)

  def load do
    spec = [description: ~c"lab", vsn: ~c"1", modules: [], registered: [],
            applications: [:kernel, :stdlib], mod: {__MODULE__, []}]
    case :application.load({:application, :lab_app, spec}) do
      :ok -> :ok
      {:error, {:already_loaded, _}} -> :ok
    end
  end
end

defmodule BeamLab.Silent do
  def inner, do: raise("swallowed")
  def swallow, do: (try do inner() rescue _ -> :swallowed end)
  def same_fn, do: (try do raise("same") rescue _ -> :swallowed end)
  def bif_swallow, do: (try do :erlang.atom_to_binary(Process.get(:x, 1)) rescue _ -> :swallowed end)
  def lookup(k), do: if(k == :x, do: {:ok, 1}, else: {:error, :nope})
  def call_dead(pid), do: (try do GenServer.call(pid, :ping) catch :exit, _ -> :caught end)
  def work(x), do: x + 1
  def loop(0), do: :ok
  def loop(n), do: (work(n); loop(n - 1))
end

defmodule BeamLab.Lazy do
  def boom, do: raise("lazy")
  def swallow, do: (try do boom() rescue _ -> :swallowed end)
end

defmodule BeamLab.RaiseLoop do
  def run(0), do: :ok
  def run(n), do: (BeamLab.Silent.same_fn(); run(n - 1))
  def for_run(n), do: for(_ <- 1..n, do: BeamLab.Silent.same_fn())
end

defmodule BeamLab.BadHandler do
  def log(_e, %{config: %{mode: :raise}}), do: raise("handler boom")
  def log(_e, %{config: %{mode: :exit}}), do: exit(:handler_exit)
  def log(_e, %{config: %{mode: :throw}}), do: throw(:handler_throw)
  def log(_e, %{config: %{mode: {:sleep, ms}}}), do: Process.sleep(ms)

  def log(_e, %{config: %{mode: {:recurse, counter}}}) do
    :counters.add(counter, 1, 1)
    if :counters.get(counter, 1) < 1000, do: :logger.error("from inside a handler")
    :ok
  end
end

defmodule BeamLab.PrimarySpy do
  @moduledoc "A primary filter that forwards every event it sees and lets it pass on unchanged."
  def filter(event, %{to: to}) do
    send(to, {:primary, event})
    :ignore
  end
end

defmodule BeamLab.MarkedSrv do
  use GenServer
  def init(m), do: (Process.put(:lab_marker, m); {:ok, m})
  def handle_cast(:raise, _), do: raise("marked")
end
