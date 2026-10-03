defmodule BeamLab.TraceTest do
  use BeamLab.Case
  alias BeamLab.Silent

  # Run fun in a fresh process traced by a fresh OTP 27+ trace session with the given patterns.
  defp traced(patterns, fun) do
    s = :trace.session_create(:lab04, self(), [])
    for {mfa, ms, flags} <- patterns, do: :trace.function(s, mfa, ms, flags)
    pid = spawn(fn -> receive do: (:go -> fun.()) end)
    ref = Process.monitor(pid)
    1 = :trace.process(s, pid, true, [:call])
    send(pid, :go)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    msgs = drain([])
    true = :trace.session_destroy(s)
    msgs
  end

  defp drain(acc) do
    receive do
      {:trace, _, _, _, _} = m -> drain([m | acc])
      {:trace, _, _, _} = m -> drain([m | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  setup do
    # first run red on 04-43: trace patterns only apply to LOADED modules (see 04-49)
    Code.ensure_loaded!(Silent)
    :ok
  end

  @exc [{:_, [], [{:exception_trace}]}]
  @ret [{:_, [], [{:return_trace}]}]

  test "04-40: rescued-and-swallowed exceptions, {:error, _} returns and catch :exit reach no handler" do
    {:ok, dead} = Task.start(fn -> :ok end)
    Process.sleep(10)
    events = run("04-40 silent", fn ->
      :swallowed = Silent.swallow()
      :swallowed = Silent.bif_swallow()
      {:error, :nope} = Silent.lookup(:y)
      :caught = Silent.call_dead(dead)
    end)
    assert events == []
  end

  test "04-43: exception_trace on a module sees a raise swallowed by its caller" do
    msgs = traced([{{Silent, :_, :_}, @exc, [:local]}], &Silent.swallow/0)
    assert Enum.any?(msgs, &match?({:trace, _, :exception_from, {Silent, :inner, 0}, {:error, %RuntimeError{message: "swallowed"}}}, &1))
  end

  test "04-44: raise+rescue inside ONE function: exception_trace sees nothing; call trace on :erlang.error/_ sees it" do
    msgs = traced([{{Silent, :_, :_}, @exc, [:local]}], &Silent.same_fn/0)
    refute Enum.any?(msgs, &match?({:trace, _, :exception_from, _, _}, &1))

    msgs = traced([{{:erlang, :error, :_}, [], [:local]}], &Silent.same_fn/0)
    assert [{:trace, _, :call, {:erlang, :error, [%RuntimeError{message: "same"} | _]}}] = msgs
  end

  test "04-45: :erlang.error/_ call tracing sees BIF errors raised by Erlang-level wrappers (atom_to_binary/1) but NOT errors raised by instructions (badmatch, badarith, element, case_clause)" do
    # first run red: atom_to_binary/1 is an Erlang wrapper in erlang.erl that calls erlang:error/3 itself
    msgs = traced([{{:erlang, :error, :_}, [], [:local]}], &Silent.bif_swallow/0)
    assert [{:trace, _, :call, {:erlang, :error, [:badarg, [1], [error_info: _]]}}] = msgs

    x = fn -> Process.get(:not_set, :a) end
    for f <- [fn -> 1 + x.() end, fn -> elem({}, x.() |> then(fn _ -> 3 end)) end,
              fn -> {:ok, _} = x.() end, fn -> case x.() do :b -> 1 end end] do
      msgs = traced([{{:erlang, :error, :_}, [], [:local]}], fn -> try do f.() rescue _ -> :swallowed end end)
      assert msgs == []
    end
  end

  test "04-46: {:error, _} returns are visible with return_trace (filtering happens in the tracer)" do
    msgs = traced([{{Silent, :lookup, 1}, @ret, [:local]}], fn -> Silent.lookup(:y) end)
    assert Enum.any?(msgs, &match?({:trace, _, :return_from, {Silent, :lookup, 1}, {:error, :nope}}, &1))
  end

  test "04-47: catch :exit around GenServer.call to a dead pid is visible via call trace on :erlang.exit/1" do
    {:ok, dead} = Task.start(fn -> :ok end)
    Process.sleep(10)
    msgs = traced([{{:erlang, :exit, 1}, [], [:local]}], fn -> Silent.call_dead(dead) end)
    # first run red: TWO exits: gen.erl exits :noproc internally, GenServer.call catches and re-exits
    assert [{:trace, _, :call, {:erlang, :exit, [:noproc]}},
            {:trace, _, :call, {:erlang, :exit, [{:noproc, {GenServer, :call, _}}]}}] = msgs
  end

  test "04-48: two sessions trace the same process independently; destroying one leaves the other" do
    s1 = :trace.session_create(:a, self(), [])
    me = self()
    t2 = spawn(fn -> receive do: (:stop -> :ok) end)
    s2 = :trace.session_create(:b, t2, [])
    for s <- [s1, s2], do: :trace.function(s, {Silent, :inner, 0}, @exc, [:local])
    pid = spawn(fn -> receive do: (:go -> Silent.swallow(); send(me, :done)) end)
    for s <- [s1, s2], do: :trace.process(s, pid, true, [:call])
    true = :trace.session_destroy(s2)
    send(pid, :go)
    assert_receive :done
    assert_receive {:trace, ^pid, :exception_from, {Silent, :inner, 0}, _}
    :trace.session_destroy(s1)
  end

  test "04-49: a trace pattern set while a module is not loaded matches 0 functions and the module stays untraced after it loads" do
    :code.purge(BeamLab.Lazy)
    :code.delete(BeamLab.Lazy)
    :code.purge(BeamLab.Lazy)
    refute :erlang.module_loaded(BeamLab.Lazy)
    s = :trace.session_create(:lazy, self(), [])
    assert :trace.function(s, {BeamLab.Lazy, :_, :_}, @exc, [:local]) == 0
    pid = spawn(fn -> receive do: (:go -> BeamLab.Lazy.swallow()) end)
    :trace.process(s, pid, true, [:call])
    send(pid, :go)
    Process.sleep(50)
    assert :erlang.module_loaded(BeamLab.Lazy)
    assert drain([]) == []
    :trace.session_destroy(s)
  end
end
