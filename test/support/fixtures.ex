defmodule Blackbox.Fixtures.Gs do
  @moduledoc false
  use GenServer
  def start(arg, opts \\ []), do: GenServer.start(__MODULE__, arg, opts)
  def start_link(arg, opts \\ []), do: GenServer.start_link(__MODULE__, arg, opts)

  @impl true
  def init(:raise), do: raise("init boom")
  def init(s), do: {:ok, s}

  @impl true
  def handle_call(:raise, _, _), do: raise(ArgumentError, "call boom")
  def handle_call(:exit, _, _), do: exit(:call_exit)
  def handle_call(:throw, _, _), do: throw(:ball)
  def handle_call(:badarg, _, s), do: {:reply, :erlang.binary_to_atom(s), s}

  def handle_call(:crumbs, _, _) do
    Blackbox.crumb("loaded order")
    raise "gs crumb boom"
  end

  def handle_call(:ok, _, s), do: {:reply, :ok, s}

  @impl true
  def handle_cast(:raise, _), do: raise("cast boom")
end

defmodule Blackbox.Fixtures.Statem do
  @moduledoc false
  @behaviour :gen_statem
  def start, do: :gen_statem.start(__MODULE__, nil, [])
  @impl true
  def callback_mode, do: :handle_event_function
  @impl true
  def init(_), do: {:ok, :idle, %{}}
  @impl true
  def handle_event({:call, _}, :raise, _, _), do: raise("statem boom")
end

defmodule Blackbox.Fixtures.Sites do
  @moduledoc false
  # Two in-app call sites into the same dependency failure. The calls are
  # not tail calls, so each site stays on the stack.
  def a(dep), do: {:ok, dep.run(1)}
  def b(dep), do: {:ok, dep.run(2)}

  def raise_here, do: {:ok, raise("here")}

  def only_ok({:ok, v}), do: v
end
