defmodule Spike.CaptureTest do
  use ExUnit.Case, async: false
  require Logger

  defmodule Gs do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_call(:boom, _, s), do: {:reply, raise(ArgumentError, "gs boom"), s}
  end

  setup do
    Spike.Buffer.set_writer(Spike.Sink.to(self()))
    Spike.Sink.collect(50)
    :ok
  end

  defp one_issue(issues, type) do
    assert [i] = Enum.filter(issues, &(&1.type == type)), inspect(issues, limit: 5)
    i
  end

  test "08-1: a raise in a plain spawn becomes one event with type, stacktrace and pid" do
    pid = spawn(fn -> raise "plain boom" end)
    i = one_issue(Spike.Sink.collect(), "RuntimeError")
    assert i.count == 1
    [s] = i.samples
    assert s.kind == :error and s.message == "plain boom"
    assert s.pid == inspect(pid)
    assert [_ | _] = s.stacktrace
  end

  test "08-2: a GenServer crash is one event carrying last_message, state and mfa" do
    {:ok, g} = GenServer.start(Gs, %{secret_state: 42})
    catch_exit(GenServer.call(g, :boom))
    i = one_issue(Spike.Sink.collect(), "ArgumentError")
    assert i.count == 1
    [s] = i.samples
    assert s.last_message =~ ":boom"
    assert s.state =~ "secret_state"
    # red on first run: meta.mfa is the LOGGING site, not the GenServer; the module is in the stacktrace
    assert s.mfa == "{:gen_server, :error_info, 7}"
    assert hd(s.stacktrace) =~ "Gs.handle_call/3"
  end

  test "08-3: a Task crash carries $callers and the process label" do
    me = self()
    Task.start(fn -> Process.set_label({:job, 7}); raise KeyError, "task boom" end)
    i = one_issue(Spike.Sink.collect(), "KeyError")
    [s] = i.samples
    assert s.callers == [inspect(me)]
    assert s.label == "{:job, 7}"
  end

  test "08-4: Logger.error without a crash is an event of kind :log" do
    Logger.error("payment 991 failed", order: 12)
    [s] = one_issue(Spike.Sink.collect(), "log").samples
    assert s.kind == :log
    assert s.message == "payment 991 failed"
  end

  test "08-5: a telemetry exception event, then the same exception crashing the process, is one occurrence" do
    {:ok, pid} =
      Task.start(fn ->
        :telemetry.span([:app, :req], %{}, fn -> raise ArithmeticError, "tele boom" end)
      end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    i = one_issue(Spike.Sink.collect(), "ArithmeticError")
    assert i.count == 1
    assert hd(i.samples).source == :telemetry
  end

  test "08-6: a :proc_lib.spawn crash reaches no handler under Elixir defaults (sasl filtered)" do
    :proc_lib.spawn(fn -> raise RuntimeError, "proc_lib boom" end)
    assert Spike.Sink.collect() == []
  end

  defp sasl_filter(on) do
    {f, cfg} = :logger.get_primary_config().filters[:logger_translator]
    :ok = :logger.remove_primary_filter(:logger_translator)
    :ok = :logger.add_primary_filter(:logger_translator, {f, %{cfg | sasl: on}})
  end

  test "08-7a: Logger.configure(handle_sasl_reports: true) at runtime does not touch the translator filter" do
    Logger.configure(handle_sasl_reports: true)
    on_exit(fn -> Logger.configure(handle_sasl_reports: false) end)
    {_, cfg} = :logger.get_primary_config().filters[:logger_translator]
    assert cfg.sasl == false
  end

  test "08-7: with the translator's sasl flag on, a :proc_lib.spawn crash is captured and a GenServer crash is still one event" do
    sasl_filter(true)
    on_exit(fn -> sasl_filter(false) end)
    :proc_lib.spawn(fn -> Process.put(:x, 1); raise RuntimeError, "proc_lib boom" end)
    {:ok, g} = GenServer.start(Gs, %{})
    catch_exit(GenServer.call(g, :boom))
    issues = Spike.Sink.collect()
    assert one_issue(issues, "RuntimeError").count == 1
    assert one_issue(issues, "ArgumentError").count == 1
    refute Enum.any?(issues, &(&1.type == "log"))
  end

  test "08-34: with sasl on, a crash of a SUPERVISED GenServer is still one event (supervisor reports are not new failures)" do
    sasl_filter(true)
    on_exit(fn -> sasl_filter(false) end)
    {:ok, sup} = Supervisor.start_link([%{id: Gs, start: {GenServer, :start_link, [Gs, %{}, [name: :sup_gs]]}}], strategy: :one_for_one)
    catch_exit(GenServer.call(:sup_gs, :boom))
    issues = Spike.Sink.collect()
    Supervisor.stop(sup)
    assert Enum.map(issues, &{&1.type, &1.count}) == [{"ArgumentError", 1}]
  end

  test "08-35: with sasl on, a brutal kill of a supervised child is one event of type exit :killed" do
    sasl_filter(true)
    on_exit(fn -> sasl_filter(false) end)
    {:ok, sup} = Supervisor.start_link([%{id: Gs, start: {GenServer, :start_link, [Gs, %{}, [name: :sup_gs2]]}}], strategy: :one_for_one)
    Process.exit(Process.whereis(:sup_gs2), :kill)
    issues = Spike.Sink.collect()
    Supervisor.stop(sup)
    assert Enum.map(issues, &{&1.type, &1.count}) == [{"exit :killed", 1}]
  end

  test "08-36: with sasl on, a supervisor giving up (max restart intensity) is captured besides the child crashes" do
    sasl_filter(true)
    on_exit(fn -> sasl_filter(false) end)
    Process.flag(:trap_exit, true)
    {:ok, sup} = Supervisor.start_link([%{id: Gs, start: {GenServer, :start_link, [Gs, %{}, [name: :sup_gs3]]}}],
                                       strategy: :one_for_one, max_restarts: 1, max_seconds: 5)
    # red on first run: the 2nd call raced the restart (:noproc); call until the supervisor gives up
    Enum.find(1..10, fn _ -> catch_exit(GenServer.call(:sup_gs3, :boom)); Process.sleep(20); not Process.alive?(sup) end)
    assert_receive {:EXIT, ^sup, :shutdown}
    issues = Spike.Sink.collect()
    # the two child crashes can land in two batches (same fingerprint; the DB upsert adds them)
    assert issues |> Enum.group_by(& &1.type, & &1.count) |> Enum.map(fn {t, c} -> {t, Enum.sum(c)} end) |> Enum.sort() ==
             [{"ArgumentError", 2}, {"exit :reached_max_restart_intensity", 1}]
    assert issues |> Enum.filter(&(&1.type == "ArgumentError")) |> Enum.map(& &1.fingerprint) |> Enum.uniq() |> length() == 1
  end

  test "08-37: GenServer.call timeouts with different args and pids are ONE issue (Sentry #933)" do
    # red on first run: an Agent also crashed on the unknown call (a 2nd issue, itself grouped 3 -> 1);
    # now the callee never replies, so only the callers' timeouts remain
    for arg <- [1, 2, 3] do
      g = spawn(fn -> Process.sleep(:infinity) end)
      Task.start(fn -> GenServer.call(g, {:slow, arg, make_ref()}, 1) end)
    end
    issues = Spike.Sink.collect(400)
    assert [%{type: "exit {:timeout, _}", count: 3}] = issues
  end

  test "08-8b: exit/1 in a plain spawn reaches no handler (the emulator logs only errors)" do
    spawn(fn -> exit({:shutdown_like, :oops}) end)
    assert Spike.Sink.collect() == []
  end

  test "08-8: exit and throw are kinds of their own" do
    Task.start(fn -> exit({:shutdown_like, :oops}) end)
    Task.start(fn -> throw(:ball) end)
    issues = Spike.Sink.collect()
    assert Enum.any?(issues, &(&1.type == "exit {:shutdown_like, _}"))
    assert Enum.any?(issues, &(&1.type == "throw"))
  end
end
