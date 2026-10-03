defmodule BeforeLab.SysTest do
  use ExUnit.Case, async: false
  alias BeforeLab.Capture

  defmodule Srv do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_call(:ping, _f, s), do: {:reply, :pong, s + 1}
    def handle_cast(:crash, _s), do: raise("boom")
    def handle_info(_, s), do: {:noreply, s}
  end

  defp terminate_report do
    receive do
      {:logged, %{msg: {:report, %{label: {:gen_server, :terminate}} = r}}, _, _} -> r
    after
      500 -> flunk("no gen_server terminate report")
    end
  end

  setup do
    Capture.attach(:cap, :error, self())
    on_exit(fn -> :logger.remove_handler(:cap) end)
    :ok
  end

  test "06-28: a GenServer started with debug: [log: 10] ships its last events in the crash report" do
    {:ok, pid} = GenServer.start(Srv, 0, debug: [log: 10])
    for _ <- 1..20, do: GenServer.call(pid, :ping)
    GenServer.cast(pid, :crash)
    r = terminate_report()
    assert length(r.log) == 10
    assert {:in, {:"$gen_cast", :crash}} in r.log
  end

  test "06-29: :sys.log/2 turns the same log on at runtime, on a running server" do
    {:ok, pid} = GenServer.start(Srv, 0)
    :ok = :sys.log(pid, {true, 5})
    GenServer.call(pid, :ping)
    GenServer.cast(pid, :crash)
    r = terminate_report()
    assert length(r.log) in 1..5
  end

  test "06-30: without the debug log the report's log is empty" do
    {:ok, pid} = GenServer.start(Srv, 0)
    GenServer.call(pid, :ping)
    GenServer.cast(pid, :crash)
    assert terminate_report().log == []
  end

  test "06-31: system_monitor long_message_queue fires for a growing mailbox (OTP 26+)" do
    prev = :erlang.system_monitor()
    on_exit(fn -> if prev == :undefined, do: :erlang.system_monitor(:undefined), else: :erlang.system_monitor(prev) end)
    :erlang.system_monitor(self(), [{:long_message_queue, {10, 100}}])
    victim = spawn(fn -> Process.sleep(:infinity) end)
    for i <- 1..150, do: send(victim, i)
    assert_receive {:monitor, ^victim, :long_message_queue, true}, 500
  end

  test "06-32: there is one system monitor per node: a second owner silently replaces the first" do
    prev = :erlang.system_monitor()
    on_exit(fn -> if prev == :undefined, do: :erlang.system_monitor(:undefined), else: :erlang.system_monitor(prev) end)
    me = self()
    :erlang.system_monitor(me, [{:long_message_queue, {10, 100}}])
    other = spawn(fn -> receive do: (:stop -> :ok) end)
    :erlang.system_monitor(other, [{:large_heap, 1_000_000}])
    victim = spawn(fn -> Process.sleep(:infinity) end)
    for i <- 1..150, do: send(victim, i)
    refute_receive {:monitor, _, :long_message_queue, _}, 300
    assert {^other, _} = :erlang.system_monitor()
    send(other, :stop)
  end

  test "06-33: system_monitor large_heap names the process that grew" do
    prev = :erlang.system_monitor()
    on_exit(fn -> if prev == :undefined, do: :erlang.system_monitor(:undefined), else: :erlang.system_monitor(prev) end)
    :erlang.system_monitor(self(), [{:large_heap, 100_000}])
    hog = spawn(fn -> l = Enum.to_list(1..500_000); Process.sleep(200); length(l) end)
    assert_receive {:monitor, ^hog, :large_heap, _info}, 1000
  end

  test "06-34: with opentelemetry_api but no SDK there is no span context to record" do
    assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
  end
end
