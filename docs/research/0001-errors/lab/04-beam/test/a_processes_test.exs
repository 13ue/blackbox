defmodule BeamLab.ProcessesTest do
  use BeamLab.Case

  # Predictions written before the first run.

  test "04-1: spawn + raise -> one :error event from the emulator, handled in :logger_proxy, no domain, crash_reason in meta" do
    pid = spawn(fn -> crash(:raise) end)
    [e] = run("04-1 spawn raise", fn -> :ok end) |> errors()
    assert e.meta.pid == pid
    # first run red: it runs in :logger_proxy (not :logger), and there is no domain at all
    assert e.handler_pid == Process.whereis(:logger_proxy)
    assert e.meta.error_logger == %{tag: :error, emulator: true}
    assert {%RuntimeError{message: "boom"}, [_ | _]} = e.meta.crash_reason
    assert {:string, _} = e.msg
    refute Map.has_key?(e.meta, :domain)
    refute Map.has_key?(e.meta, :mfa)
  end

  test "04-2: spawn + throw -> one :error event, crash_reason {%ErlangError{original: {:nocatch, :boom}}, stack}" do
    spawn(fn -> crash(:throw) end)
    [e] = run("04-2 spawn throw", fn -> :ok end) |> errors()
    # first run red: the translator normalizes it to an ErlangError, the throw kind is lost
    assert {%ErlangError{original: {:nocatch, :boom}}, _} = e.meta.crash_reason
  end

  test "04-3: spawn + exit(:boom) -> nothing is logged at all" do
    spawn(fn -> crash(:exit) end)
    assert run("04-3 spawn exit", fn -> :ok end) == []
  end

  test "04-4: spawn + BIF badarg -> one :error event with ArgumentError" do
    spawn(fn -> crash(:badarg) end)
    [e] = run("04-4 spawn badarg", fn -> :ok end) |> errors()
    assert {%ArgumentError{}, _} = e.meta.crash_reason
  end

  test "04-5: spawn_link + raise -> crash logged once; a linked plain parent dies silently" do
    parent =
      spawn(fn ->
        spawn_link(fn -> crash(:raise) end)
        Process.sleep(:infinity)
      end)

    ref = Process.monitor(parent)
    events = run("04-5 spawn_link raise", fn -> :ok end)
    assert_received {:DOWN, ^ref, :process, ^parent, {%RuntimeError{}, _}}
    assert length(errors(events)) == 1
  end

  test "04-6: Task.start + raise -> one :error report from Task, meta has crash_reason, mfa? and callers" do
    {:ok, pid} = Task.start(fn -> crash(:raise) end)
    [e] = run("04-6 Task.start raise", fn -> :ok end) |> errors()
    assert e.meta.pid == pid
    assert e.handler_pid == pid
    assert {%RuntimeError{}, _} = e.meta.crash_reason
    assert e.meta.callers == [self()]
    assert {:report, %{label: {Task.Supervisor, :terminating}}} = e.msg
  end

  test "04-7: Task.start + exit(:boom) -> Task logs non-normal exits too" do
    Task.start(fn -> crash(:exit) end)
    [e] = run("04-7 Task.start exit", fn -> :ok end) |> errors()
    assert {:boom, _} = e.meta.crash_reason
  end

  test "04-8: Task.start + exit({:shutdown, x}) / :normal -> nothing logged" do
    Task.start(fn -> exit({:shutdown, :x}) end)
    Task.start(fn -> exit(:normal) end)
    assert run("04-8 Task shutdown/normal", fn -> :ok end) == []
  end

  test "04-9: Task.async + await (both sides): task crash logged once; the caller dies by the link, not logged" do
    caller =
      spawn(fn ->
        t = Task.async(fn -> crash(:raise) end)
        Task.await(t)
      end)

    ref = Process.monitor(caller)
    events = run("04-9 Task.async await", fn -> :ok end)
    assert_received {:DOWN, ^ref, :process, ^caller, {%RuntimeError{}, _}}
    assert [%{meta: %{callers: [^caller]}}] = errors(events)
  end

  test "04-10: Task.Supervisor.async_nolink: task crash logged once, caller sees {:exit, reason} from yield; meta has callers, not ancestors" do
    {:ok, sup} = Task.Supervisor.start_link()
    t = Task.Supervisor.async_nolink(sup, fn -> crash(:raise) end)
    events = run("04-10 async_nolink", fn -> :ok end)
    assert {:exit, {%RuntimeError{}, _}} = Task.yield(t, 0)
    [e] = errors(events)
    assert e.meta.callers == [self()]
    # first run red: Task reports carry callers but no ancestors (those come only from proc_lib crash reports)
    refute Map.has_key?(e.meta, :ancestors)
    assert {:report, %{report: %{starter: starter}}} = e.msg
    assert starter == self()
  end

  test "04-11: Task.await timeout: caller exits {:timeout, {Task, :await, _}}; nothing logged for the caller (plain process)" do
    caller = spawn(fn -> Task.async(fn -> Process.sleep(1000) end) |> Task.await(10) end)
    ref = Process.monitor(caller)
    events = run("04-11 Task.await timeout", fn -> :ok end)
    assert_received {:DOWN, ^ref, :process, ^caller, {:timeout, {Task, :await, _}}}
    assert errors(events) == []
  end

  test "04-12: exit(:kill) from self and Process.exit(pid, :kill) -> nothing logged" do
    spawn(fn -> exit(:kill) end)
    p = spawn(fn -> Process.sleep(:infinity) end)
    Process.exit(p, :kill)
    assert run("04-12 kill", fn -> :ok end) == []
  end

  test "04-13: Logger.error without a crash: handled in the caller, domain [:elixir], mfa/file/line in meta" do
    require Logger
    [e] = run("04-13 Logger.error", fn -> Logger.error("hello") end)
    assert e.handler_pid == self()
    assert e.meta.domain == [:elixir]
    assert {BeamLab.ProcessesTest, _, 1} = e.meta.mfa
    assert is_integer(e.meta.line)
    assert e.msg == {:string, "hello"}
  end

  test "04-14: :erlang.error(:foo) in a plain process -> logged like raise, crash_reason ErlangError" do
    spawn(fn -> :erlang.error(:foo) end)
    [e] = run("04-14 erlang.error", fn -> :ok end) |> errors()
    assert {%ErlangError{original: :foo}, _} = e.meta.crash_reason
  end
end
