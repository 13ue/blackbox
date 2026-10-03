defmodule BeamLab.TraceCostTest do
  use BeamLab.Case
  alias BeamLab.Silent

  @moduletag timeout: 300_000
  @n 100_000
  @exc [{:_, [], [{:exception_trace}]}]
  @log Path.expand("../../../logs/04-cost.log", __DIR__)

  setup do
    Code.ensure_loaded!(Silent)
    :ok
  end

  # a tracer sink that counts messages
  defp sink do
    spawn(fn -> count(0) end)
  end

  defp count(n) do
    receive do
      {:count, to} -> send(to, {:count, n})
      _ -> count(n + 1)
    end
  end

  defp sink_count(s) do
    # wait for the mailbox to settle
    Stream.repeatedly(fn -> Process.sleep(50); Process.info(s, :message_queue_len) end)
    |> Enum.find(&match?({:message_queue_len, 0}, &1))
    send(s, {:count, self()})
    receive do: ({:count, n} -> n)
  end

  # median µs of `work` run 3x in a fresh process, with optional session setup
  defp measure(label, setup, work) do
    runs =
      for _ <- 1..3 do
        tracer = sink()
        s = :trace.session_create(:cost, tracer, [])
        {setup_us, trace_me?} = :timer.tc(fn -> setup.(s) end)
        me = self()
        pid = spawn(fn -> receive do: (:go -> send(me, {:us, :timer.tc(work) |> elem(0)})) end)
        if trace_me?, do: :trace.process(s, pid, true, [:call])
        send(pid, :go)
        us = receive do: ({:us, us} -> us)
        msgs = sink_count(tracer)
        :trace.session_destroy(s)
        Process.exit(tracer, :kill)
        {us, setup_us, msgs}
      end

    {us, setup_us, msgs} = Enum.sort(runs) |> Enum.at(1)
    line = "#{String.pad_trailing(label, 58)} #{String.pad_leading("#{us}", 9)} us  setup #{setup_us} us  msgs #{msgs}"
    File.write!(@log, line <> "\n", [:append])
    %{us: us, setup_us: setup_us, msgs: msgs}
  end

  test "04-51: costs of trace sessions on 100k tiny calls (Silent.loop/1)" do
    File.write!(@log, "\n== #{DateTime.utc_now()} #{:erlang.system_info(:system_architecture)} OTP #{System.otp_release()} schedulers #{System.schedulers_online()}\n", [:append])
    big = 2_000_000
    work = fn -> Silent.loop(big) end
    small = fn -> Silent.loop(@n) end
    # ns per loop iteration (one loop/1 + one work/1 call)
    ns = fn %{us: us}, n -> us * 1000 / n end
    base = measure("a baseline, no pattern (2M iter)", fn _ -> false end, work)

    own = measure("b {Silent,_,_} exception_trace, process traced (100k iter)",
      fn s -> :trace.function(s, {Silent, :_, :_}, @exc, [:local]); true end, small)

    other = measure("c {Silent,_,_} exception_trace, NOT traced (2M iter)",
      fn s -> :trace.function(s, {Silent, :_, :_}, @exc, [:local]); false end, work)

    errs = measure("d erlang:error/exit/throw call trace, traced (2M iter)",
      fn s -> for f <- [:error, :exit, :throw], do: :trace.function(s, {:erlang, f, :_}, [], [:local]); true end, work)

    all = measure("e {_,_,_} exception_trace (all loaded), traced (100k iter)",
      fn s -> n = :trace.function(s, {:_, :_, :_}, @exc, [:local]); File.write!(@log, "e matched functions: #{n}\n", [:append]); true end, small)

    all_other = measure("f {_,_,_} exception_trace (all loaded), NOT traced (2M iter)",
      fn s -> :trace.function(s, {:_, :_, :_}, @exc, [:local]); false end, work)

    r = %{base: ns.(base, big), own: ns.(own, @n), other: ns.(other, big), errs: ns.(errs, big),
          all: ns.(all, @n), all_other: ns.(all_other, big)}
    File.write!(@log, "ns per iteration: #{inspect(r)}\n", [:append])

    # predictions (first run: own/all/errs green; other/all_other red at < 2x)
    assert r.own > 5 * r.base
    assert own.msgs >= 2 * @n
    assert r.other < 6 * r.base
    # 1.3x was red once in 3 runs: noise on a 3 ns loop
    assert r.errs < 1.5 * r.base
    assert errs.msgs == 0
    assert r.all > 5 * r.base
    assert r.all_other < 6 * r.base
    assert all.setup_us > 1_000
  end

  test "04-52: cost of a traced raise+rescue: 100k swallowed exceptions with erlang:error call trace on vs off" do
    # tail-recursive loop: a `for` here made every raise O(stack depth), see 04-53
    work = fn -> BeamLab.RaiseLoop.run(100_000) end
    off = measure("g 100k raise+rescue, no pattern", fn _ -> false end, work)
    on = measure("h 100k raise+rescue, erlang:error traced", fn s -> :trace.function(s, {:erlang, :error, :_}, [], [:local]); true end, work)
    assert on.msgs == 100_000
    # prediction was < 2x; first run red: ~7x on the raise path, i.e. ~0.35 us extra per raise
    assert on.us < 12 * off.us
    assert (on.us - off.us) / 100_000 < 1.0
  end

  test "04-50: silent mode suppresses call messages AND exception_from (so exception_trace cannot be made cheap that way)" do
    s = :trace.session_create(:silent, self(), [])
    :trace.function(s, {Silent, :_, :_}, [{:_, [], [{:exception_trace}, {:silent, true}]}], [:local])
    pid = spawn(fn -> receive do: (:go -> Silent.swallow()) end)
    :trace.process(s, pid, true, [:call, :silent])
    send(pid, :go)
    Process.sleep(50)
    msgs = Stream.repeatedly(fn -> receive do m -> m after 0 -> nil end end) |> Enum.take_while(& &1)
    :trace.session_destroy(s)
    File.write!(@log, "04-50 silent msgs: #{inspect(msgs)}\n", [:append])
    # first run red: silent mode inhibits the exception_from message too
    assert msgs == []
  end

  test "04-53: raising is O(stack depth): a swallowed raise inside a 100k-deep body recursion costs >100x a shallow one" do
    {shallow, _} = :timer.tc(fn -> BeamLab.RaiseLoop.run(100_000) end)
    {deep, _} = :timer.tc(fn -> BeamLab.RaiseLoop.for_run(100_000) end)
    File.write!(@log, "04-53 100k raise+rescue: tail loop #{shallow} us, inside `for` (deep stack) #{deep} us\n", [:append])
    assert deep > 100 * shallow
  end
end
