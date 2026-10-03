defmodule BeforeLab.TraceTest do
  use ExUnit.Case, async: false
  alias BeforeLab.Recorder

  defmodule Work do
    def step(x), do: x + 1
    def loop do
      receive do
        {:work, x} -> step(x); loop()
        :crash -> raise "worker died"
      end
    end
  end

  test "06-36: a trace session records the last N messages a process received, readable after it dies" do
    {:ok, rec} = Recorder.start(:blackbox_a)
    s = Recorder.session(rec)
    w = spawn(&Work.loop/0)
    :trace.process(s, w, true, [:receive])
    for i <- 1..30, do: send(w, {:work, i})
    send(w, :crash)
    Process.sleep(100)
    last = Recorder.dump(rec, w)
    assert length(last) == 20
    # first run (red): expected :crash to be the last entry. Truth: receive tracing also records the VM-internal
    # replies the process gets while dying (here the code server loading RuntimeError), so filter them.
    assert {:trace, w, :receive, :crash} in last
    assert {:trace, w, :receive, {:code_server, {:module, RuntimeError}}} in last or List.last(last) == {:trace, w, :receive, :crash}
  end

  test "06-37: two sessions trace the same process independently (no fight over the single tracer slot)" do
    {:ok, a} = Recorder.start(:blackbox_b)
    {:ok, b} = Recorder.start(:other_tool)
    w = spawn(&Work.loop/0)
    :trace.process(Recorder.session(a), w, true, [:receive])
    :trace.process(Recorder.session(b), w, true, [:receive])
    # legacy (global) tracing on the same pid is also still possible
    1 = :erlang.trace(w, true, [:receive, {:tracer, self()}])
    send(w, {:work, 1})
    Process.sleep(50)
    assert [{:trace, ^w, :receive, {:work, 1}}] = Recorder.dump(a, w)
    assert [{:trace, ^w, :receive, {:work, 1}}] = Recorder.dump(b, w)
    assert_received {:trace, ^w, :receive, {:work, 1}}
  end

  test "06-38: call tracing with a session records the last calls of a function in one process" do
    {:ok, rec} = Recorder.start(:blackbox_c)
    s = Recorder.session(rec)
    w = spawn(&Work.loop/0)
    :trace.process(s, w, true, [:call])
    :trace.function(s, {Work, :step, 1}, [{:_, [], [{:return_trace}]}], [:local])
    send(w, {:work, 41})
    Process.sleep(50)
    assert [{:trace, ^w, :call, {Work, :step, [41]}}, {:trace, ^w, :return_from, {Work, :step, 1}, 42}] = Recorder.dump(rec, w)
  end

  test "06-39: OTP 28 trace:system gives each session its own system monitor (two owners, both notified)" do
    {:ok, a} = Recorder.start(:mon_a)
    {:ok, b} = Recorder.start(:mon_b)
    :ok = :trace.system(Recorder.session(a), :long_message_queue, {10, 100})
    :ok = :trace.system(Recorder.session(b), :long_message_queue, {10, 100})
    me = self()
    # the recorders drop non-trace messages; check with raw pids instead
    sa = :trace.session_create(:mon_raw_a, me, [])
    :ok = :trace.system(sa, :long_message_queue, {10, 100})
    other = spawn(fn -> receive do: (m -> send(me, {:other_got, m})) end)
    sb = :trace.session_create(:mon_raw_b, other, [])
    :ok = :trace.system(sb, :long_message_queue, {10, 100})
    victim = spawn(fn -> Process.sleep(:infinity) end)
    for i <- 1..150, do: send(victim, i)
    assert_receive {:monitor, ^victim, :long_message_queue, true}, 500
    assert_receive {:other_got, {:monitor, ^victim, :long_message_queue, true}}, 500
    :trace.session_destroy(sa)
    :trace.session_destroy(sb)
  end

  test "06-40: the session dies with its last strong handle (creator exits, handle garbage collected)" do
    me = self()
    spawn(fn ->
      s = :trace.session_create(:short_lived, me, [])
      w = spawn(fn -> Process.sleep(:infinity) end)
      :trace.process(s, w, true, [:receive])
      # first run broke here on a test bug (a bad session_info/1 pipe crashed this helper); now just report w
      send(me, {:made, w})
      _ = s
    end)
    assert_receive {:made, w}
    Process.sleep(50)
    :erlang.garbage_collect()
    send(w, :hello)
    refute_receive {:trace, ^w, :receive, :hello}, 200
  end

  test "06-40b: control: while the creator holds the handle, the same setup does deliver" do
    me = self()
    holder = spawn(fn ->
      s = :trace.session_create(:long_lived, me, [])
      w = spawn(fn -> Process.sleep(:infinity) end)
      :trace.process(s, w, true, [:receive])
      send(me, {:made, w})
      receive do: (:stop -> :trace.session_destroy(s))
    end)
    assert_receive {:made, w}
    :erlang.garbage_collect()
    send(w, :hello)
    assert_receive {:trace, ^w, :receive, :hello}, 200
    send(holder, :stop)
  end

  test "06-41: a tracer that cannot keep up gets an unbounded mailbox (the VM never drops trace messages)" do
    slow = spawn(fn -> Process.sleep(:infinity) end)
    s = :trace.session_create(:flood, slow, [])
    # flaky in the first full-suite run (seed 425637): the worker could finish before the flags were set. Wait for :go.
    w = spawn(fn -> receive do: (:go -> :ok); for i <- 1..100_000, do: Work.step(i); Process.sleep(:infinity) end)
    :trace.process(s, w, true, [:call])
    :trace.function(s, {Work, :step, 1}, true, [:local])
    send(w, :go)
    Process.sleep(500)
    {:message_queue_len, n} = Process.info(slow, :message_queue_len)
    :trace.session_destroy(s)
    assert n > 50_000
  end
end
