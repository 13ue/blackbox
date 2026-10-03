defmodule BeforeLab.Ring.Pdict do
  @moduledoc "Per-process breadcrumb ring in the process dictionary: {count, newest-first list}, trimmed at 2*max."
  @key :"$blackbox_crumbs"
  @max 50

  def add(crumb) do
    case Process.get(@key) do
      nil -> Process.put(@key, {1, [crumb]})
      {n, list} when n >= 2 * @max -> Process.put(@key, {@max + 1, [crumb | Enum.take(list, @max)]})
      {n, list} -> Process.put(@key, {n + 1, [crumb | list]})
    end

    :ok
  end

  def read, do: from_value(Process.get(@key))

  def read(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> from_value(:proplists.get_value(@key, dict, nil))
      nil -> []
    end
  end

  def clear, do: Process.delete(@key)
  def key, do: @key

  defp from_value(nil), do: []
  defp from_value({_, list}), do: list |> Enum.take(@max) |> Enum.reverse()
end

defmodule BeforeLab.Ring.Ets do
  @moduledoc "Shared ordered_set keyed {pid, slot}; slot counter kept in the writer's pdict (one ETS op per crumb)."
  @tab :blackbox_crumbs
  @max 50

  def new do
    if :ets.whereis(@tab) == :undefined do
      :ets.new(@tab, [:ordered_set, :public, :named_table, write_concurrency: true, read_concurrency: true])
    end

    :ok
  end

  def add(crumb) do
    i = Process.get(:"$blackbox_i", 0)
    Process.put(:"$blackbox_i", i + 1)
    :ets.insert(@tab, {{self(), rem(i, @max)}, i, crumb})
    :ok
  end

  def read(pid) do
    :ets.select(@tab, [{{{pid, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  def delete(pid), do: :ets.match_delete(@tab, {{pid, :_}, :_, :_})
  def size, do: :ets.info(@tab, :size)
  def memory_bytes, do: :ets.info(@tab, :memory) * :erlang.system_info(:wordsize)
end

defmodule BeforeLab.Ring.Server do
  @moduledoc "One GenServer holding all rings (the naive design)."
  use GenServer
  @max 50

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def add(crumb), do: GenServer.cast(__MODULE__, {:add, self(), crumb})
  def read(pid), do: GenServer.call(__MODULE__, {:read, pid})

  @impl true
  def init(s), do: {:ok, s}

  @impl true
  def handle_cast({:add, pid, crumb}, s) do
    {:noreply, Map.update(s, pid, [crumb], &Enum.take([crumb | &1], @max))}
  end

  @impl true
  def handle_call({:read, pid}, _from, s), do: {:reply, Enum.reverse(Map.get(s, pid, [])), s}
end
