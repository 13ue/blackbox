defmodule BeforeLab.CrashContextTest do
  use ExUnit.Case, async: false
  alias BeforeLab.{Capture, Ring}

  defmodule Srv do
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call(:crash, _from, s), do: raise("call boom #{map_size(s)}")
    def handle_cast(:crash, _s), do: raise("cast boom")
    def handle_cast({:crumb, c}, s), do: (Ring.Pdict.add(c); {:noreply, s})
    def handle_cast({:meta, kv}, s), do: (Logger.metadata(kv); {:noreply, s})
    def handle_cast(:exit, _s), do: exit(:gone)
  end

  defmodule Scrubbed do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_cast(:crash, _s), do: raise("x")
    def format_status(status), do: Map.update!(status, :state, fn s -> Map.put(s, :password, "[scrubbed]") end)
  end

  setup do
    Capture.attach(:cap, :all, self())
    on_exit(fn -> :logger.remove_handler(:cap) end)
    :ok
  end

  # all events whose handler ran within 300ms
  defp events(acc \\ []) do
    receive do
      {:logged, e, runner, crumbs} -> events([{e, runner, crumbs} | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp report(e), do: match?(%{msg: {:report, _}}, e) && elem(e.msg, 1)

  test "06-8: a GenServer crash is logged from inside the dying process; the handler reads its pdict ring" do
    {:ok, pid} = GenServer.start(Srv, %{})
    GenServer.cast(pid, {:crumb, :loaded_board})
    GenServer.cast(pid, {:crumb, :applied_op})
    GenServer.cast(pid, :crash)
    evs = events()
    assert [{_, ^pid, crumbs} | _] = Enum.filter(evs, fn {e, _, _} -> e.level == :error end)
    assert crumbs == [:loaded_board, :applied_op]
  end

  test "06-9: Elixir's primary translator filter drops the proc_lib crash report (with the pdict) unless sasl is on" do
    # first run (red): expected the crash report to reach an :all handler. Truth: Elixir installs a PRIMARY filter
    # logger_translator with sasl: false (config :logger, handle_sasl_reports: false), so no handler ever sees it.
    find = fn evs -> Enum.find_value(evs, fn {e, _, _} -> r = report(e); r && r[:label] == {:proc_lib, :crash} && r end) end
    {:ok, pid} = GenServer.start(Srv, %{})
    GenServer.cast(pid, {:crumb, :x})
    GenServer.cast(pid, :crash)
    assert find.(events()) == nil

    {fun, conf} = :logger.get_primary_config().filters[:logger_translator]
    :logger.remove_primary_filter(:logger_translator)
    :logger.add_primary_filter(:logger_translator, {fun, %{conf | sasl: true}})
    on_exit(fn ->
      :logger.remove_primary_filter(:logger_translator)
      :logger.add_primary_filter(:logger_translator, {fun, conf})
    end)
    {:ok, pid} = GenServer.start(Srv, %{})
    GenServer.cast(pid, {:crumb, :x})
    GenServer.cast(pid, :crash)
    crash = find.(events())
    [info | _] = crash.report
    assert {Ring.Pdict.key(), {1, [:x]}} in info[:dictionary]
  end

  test "06-10: a Task crash runs the handler in the task; $callers names the parent, whose ring is readable" do
    Ring.Pdict.clear()
    Ring.Pdict.add(:request_started)
    Ring.Pdict.add(:loaded_user)
    me = self()
    {:ok, t} = Task.start(fn -> raise "task boom" end)
    evs = events()
    {_, runner, _} = Enum.find(evs, fn {e, _, _} -> e.level == :error end)
    assert runner == t
    # the parent can be found from inside the handler: Process.info(parent, :dictionary)
    assert Ring.Pdict.read(me) == [:request_started, :loaded_user]
  end

  test "06-11: a plain spawn crash is logged outside the dead process; its pdict is gone" do
    pid = spawn(fn -> Ring.Pdict.add(:lost); raise "raw boom" end)
    evs = events()
    {_e, runner, crumbs} = Enum.find(evs, fn {e, _, _} -> e.level == :error end)
    refute runner == pid
    assert crumbs == []
    assert Process.info(pid, :dictionary) == nil
  end

  test "06-12: a crash inside GenServer.call reports last_message, state and the client pid" do
    {:ok, pid} = GenServer.start(Srv, %{a: 1})
    me = self()
    catch_exit(GenServer.call(pid, :crash))
    evs = events()
    r = Enum.find_value(evs, fn {e, _, _} -> r = report(e); r && r[:label] == {:gen_server, :terminate} && r end)
    # first run (red): expected the {:"$gen_call", from, msg} envelope. Truth: the bare request, sender in client_info
    assert r.last_message == :crash
    assert r.state == %{a: 1}
    assert {^me, {^me, stack}} = r.client_info
    assert is_list(stack)
  end

  test "06-13: a crash inside a cast has no sender in the report" do
    {:ok, pid} = GenServer.start(Srv, %{})
    GenServer.cast(pid, :crash)
    evs = events()
    r = Enum.find_value(evs, fn {e, _, _} -> r = report(e); r && r[:label] == {:gen_server, :terminate} && r end)
    assert r.last_message == {:"$gen_cast", :crash}
    assert r.client_info == :undefined
  end

  test "06-14: format_status/1 scrubs the state before it reaches the report" do
    {:ok, pid} = GenServer.start(Scrubbed, %{password: "hunter2"})
    GenServer.cast(pid, :crash)
    evs = events()
    r = Enum.find_value(evs, fn {e, _, _} -> r = report(e); r && r[:label] == {:gen_server, :terminate} && r end)
    assert r.state == %{password: "[scrubbed]"}
    # but the proc_lib crash report next to it: does its dictionary/other fields leak the state? (no state there)
  end

  test "06-15: Logger.metadata is not inherited by a Task, $callers is" do
    Logger.metadata(request_id: "req-1")
    me = self()
    {md, callers} = Task.async(fn -> {Logger.metadata(), Process.get(:"$callers")} end) |> Task.await()
    assert md == []
    assert callers == [me]
  end

  test "06-16: Logger.metadata set inside a GenServer rides on its crash event's meta" do
    {:ok, pid} = GenServer.start(Srv, %{})
    GenServer.cast(pid, {:meta, request_id: "req-7"})
    GenServer.cast(pid, :crash)
    evs = events()
    {e, _, _} = Enum.find(evs, fn {e, _, _} -> e.level == :error end)
    assert e.meta[:request_id] == "req-7"
  end

  test "06-17: a GenServer's $ancestors name the starter, never the request that called it" do
    me = self()
    {:ok, pid} = GenServer.start(Srv, %{})
    {:dictionary, d} = Process.info(pid, :dictionary)
    assert d[:"$ancestors"] == [me]
    GenServer.stop(pid)
  end
end
