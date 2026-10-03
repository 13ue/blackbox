defmodule BeamLab.OtpTest do
  use BeamLab.Case
  alias BeamLab.{Srv, Sasl}

  defp sasl(_) do
    Sasl.set(true)
    on_exit(fn -> Sasl.set(false) end)
  end

  defp call_catch(pid, msg) do
    try do
      GenServer.call(pid, msg, 1000)
    catch
      :exit, r -> {:caught, r}
    end
  end

  describe "default Elixir config (handle_sasl_reports: false)" do
    test "04-15: GenServer init raise -> start returns {:error, _} and nothing reaches handlers" do
      events = run("04-15 init raise", fn ->
        assert {:error, {%RuntimeError{}, _}} = GenServer.start(Srv, :raise)
      end)
      assert events == []
    end

    test "04-17: handle_call raise -> one {:gen_server, :terminate} :error report in the server process; caller exits" do
      {:ok, pid} = GenServer.start(Srv, %{n: 1})
      [e] = run("04-17 handle_call raise", fn ->
        assert {:caught, {{%RuntimeError{}, _}, {GenServer, :call, _}}} = call_catch(pid, {:do, :raise})
      end)
      assert e.level == :error
      assert e.meta.domain == [:otp]
      assert e.handler_pid == pid
      # first run red: the gen_server report is FLAT (no nested :report key)
      assert {:report, %{label: {:gen_server, :terminate}} = r} = e.msg
      assert Enum.sort(Map.keys(r) -- [:elixir_translation]) ==
               Enum.sort([:label, :name, :reason, :log, :state, :last_message, :process_label, :client_info])
      assert r.last_message == {:do, :raise}
      assert r.state == %{n: 1}
      # client_info = {client_pid, {client_pid, client's current stacktrace}}: the caller's stack for free
      assert {client, {client, [_ | _] = client_stack}} = r.client_info
      assert client == self()
      assert Enum.any?(client_stack, &match?({BeamLab.OtpTest, :call_catch, 2, _}, &1))
      assert Map.has_key?(r, :process_label)
      assert {%RuntimeError{}, _} = e.meta.crash_reason
    end

    test "04-18: handle_cast raise -> same report, client_info :undefined" do
      {:ok, pid} = GenServer.start(Srv, %{})
      [e] = run("04-18 handle_cast raise", fn -> GenServer.cast(pid, {:do, :raise}) end)
      assert {:report, %{label: {:gen_server, :terminate}} = r} = e.msg
      assert r.last_message == {:"$gen_cast", {:do, :raise}}
      assert r.client_info == :undefined
    end

    test "04-19: handle_info throw -> reason {:bad_return_value, :boom}, no stacktrace" do
      {:ok, pid} = GenServer.start(Srv, %{})
      [e] = run("04-19 handle_info raise", fn -> send(pid, {:do, :throw}) end)
      # first run red: a throw inside a gen_server callback is a *return value*, so the reason is
      # {:bad_return_value, :boom} with no stacktrace at all
      assert {:report, %{last_message: {:do, :throw}, reason: {:bad_return_value, :boom}}} = e.msg
      assert {{:bad_return_value, :boom}, []} = e.meta.crash_reason
    end

    test "04-20: {:stop, :normal | :shutdown | {:shutdown, x}} -> nothing logged" do
      for r <- [:normal, :shutdown, {:shutdown, :x}] do
        {:ok, pid} = GenServer.start(Srv, %{})
        GenServer.cast(pid, {:stop, r})
      end
      assert run("04-20 stop normal/shutdown", fn -> :ok end) == []
    end

    test "04-21: {:stop, :boom} (no exception) -> logged, crash_reason {:boom, []}" do
      {:ok, pid} = GenServer.start(Srv, %{})
      [e] = run("04-21 stop boom", fn -> GenServer.cast(pid, {:stop, :boom}) end)
      assert {:boom, []} = e.meta.crash_reason
    end

    test "04-22: terminate raises -> one report whose reason is the terminate exception" do
      {:ok, pid} = GenServer.start(Srv, %{raise_in_terminate: true})
      [e] = run("04-22 terminate raise", fn -> GenServer.cast(pid, {:do, :exit}) end)
      assert {%RuntimeError{message: "terminate boom"}, _} = e.meta.crash_reason
    end

    test "04-23: call timeout -> caller exits {:timeout, _}; server fine; nothing logged" do
      {:ok, pid} = GenServer.start(Srv, %{})
      events = run("04-23 call timeout", fn ->
        assert {:caught, {:timeout, {GenServer, :call, _}}} =
                 (try do GenServer.call(pid, :sleep, 10) catch :exit, r -> {:caught, r} end)
      end, 500)
      assert events == []
      assert GenServer.call(pid, :ping) == :pong
    end

    test "04-24: unexpected message to a `use GenServer` without handle_info -> :error {GenServer, :no_handle_info}" do
      {:ok, pid} = Agent.start(fn -> 0 end)
      # Agent.Server implements handle_info; use a bare GenServer module instead
      Agent.stop(pid)
      defmodule Bare do
        use GenServer
        def init(s), do: {:ok, s}
      end
      {:ok, pid} = GenServer.start(Bare, 0)
      [e] = run("04-24 no_handle_info", fn -> send(pid, :stray) end)
      assert e.level == :error
      assert {:report, %{label: {GenServer, :no_handle_info}}} = e.msg
      assert Process.alive?(pid)
    end

    test "04-25: Agent.get with a raising fun -> the Agent server crashes with a gen_server report" do
      {:ok, a} = Agent.start(fn -> 0 end)
      [e] = run("04-25 Agent", fn ->
        catch_exit(Agent.get(a, fn _ -> raise "agent boom" end))
      end)
      assert {:report, %{label: {:gen_server, :terminate}, last_message: {:get, _}}} = e.msg
    end

    test "04-26: :gen_statem raise -> {:gen_statem, :terminate} report" do
      {:ok, pid} = :gen_statem.start(BeamLab.Statem, %{d: 1}, [])
      [e] = run("04-26 gen_statem", fn -> catch_exit(:gen_statem.call(pid, {:do, :raise})) end)
      assert {:report, %{label: {:gen_statem, :terminate}} = r} = e.msg
      assert r.state == {:idle, %{d: 1}}
      # gen_statem differs: reason is {class, reason, stack}, it has queue + modules, no last_message
      assert {:error, %RuntimeError{}, [_ | _]} = r.reason
      assert [{{:call, _}, {:do, :raise}}] = r.queue
      refute Map.has_key?(r, :last_message)
      assert {%RuntimeError{}, _} = e.meta.crash_reason
    end

    test "04-27: supervised child crash -> only the child's gen_server report; the supervisor's report is filtered" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one)
      Process.unlink(sup)
      [{_, child, _, _}] = Supervisor.which_children(sup)
      events = run("04-27 sup restart", fn -> GenServer.cast(child, {:do, :raise}) end)
      assert [%{msg: {:report, %{label: {:gen_server, :terminate}}}}] = events
      [{_, child2, _, _}] = Supervisor.which_children(sup)
      assert child2 != child
      Supervisor.stop(sup)
    end

    test "04-28: supervisor max intensity -> the supervisor dies with :shutdown and that is NOT logged" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one, max_restarts: 1, max_seconds: 5)
      Process.unlink(sup)
      ref = Process.monitor(sup)
      events = run("04-28 max intensity", fn ->
        for _ <- 1..2 do
          [{_, c, _, _}] = Supervisor.which_children(sup)
          GenServer.cast(c, {:do, :raise})
          Process.sleep(50)
        end
      end)
      assert_received {:DOWN, ^ref, :process, ^sup, :shutdown}
      assert length(events) == 2
      assert Enum.all?(events, &match?(%{msg: {:report, %{label: {:gen_server, :terminate}}}}, &1))
    end

    test "04-29: brutal kill of a supervised GenServer -> nothing logged" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one)
      Process.unlink(sup)
      [{_, c, _, _}] = Supervisor.which_children(sup)
      assert run("04-29 brutal kill", fn -> Process.exit(c, :kill) end) == []
      Supervisor.stop(sup)
    end

    test "04-30: exit signal to a trapping GenServer from a non-parent -> becomes an {:EXIT} message; Srv has no clause -> it crashes with FunctionClauseError" do
      {:ok, pid} = GenServer.start(Srv, {:trap, %{}})
      [e] = run("04-30 trapped exit", fn -> Process.exit(pid, :boom) end)
      assert {%FunctionClauseError{}, _} = e.meta.crash_reason
      assert {:report, %{last_message: {:EXIT, _, :boom}}} = e.msg
    end
  end

  describe "with handle_sasl_reports: true" do
    setup :sasl

    test "04-16: GenServer init raise -> a proc_lib crash report (domain [:otp, :sasl]) with the full process snapshot" do
      [e] = run("04-16 init raise sasl", fn -> GenServer.start(Srv, :raise) end)
      assert e.meta.domain == [:otp, :sasl]
      assert {:report, %{label: {:proc_lib, :crash}, report: [info, _neighbours]}} = e.msg
      for k <- [:initial_call, :pid, :registered_name, :process_label, :error_info, :ancestors,
                :message_queue_len, :messages, :links, :dictionary, :trap_exit, :status,
                :heap_size, :stack_size, :reductions],
          do: assert(Keyword.has_key?(info, k), "missing #{k}")
      assert is_list(e.meta.ancestors)
    end

    test "04-27s: supervised child crash with sasl -> gen_server report + crash report + supervisor child_terminated + progress" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one)
      Process.unlink(sup)
      [{_, child, _, _}] = Supervisor.which_children(sup)
      events = run("04-27s sup restart sasl", fn -> GenServer.cast(child, {:do, :raise}) end)
      labels = for %{msg: {:report, %{label: l}}} <- events, do: l
      assert {:gen_server, :terminate} in labels
      assert {:proc_lib, :crash} in labels
      assert {:supervisor, :child_terminated} in labels
      assert {:supervisor, :progress} in labels
      Supervisor.stop(sup)
    end

    test "04-28s: max intensity with sasl -> {:supervisor, :shutdown} report" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one, max_restarts: 0)
      Process.unlink(sup)
      [{_, c, _, _}] = Supervisor.which_children(sup)
      events = run("04-28s max intensity sasl", fn -> GenServer.cast(c, {:do, :raise}) end)
      labels = for %{msg: {:report, %{label: l}}} <- events, do: l
      assert {:supervisor, :shutdown} in labels
    end

    test "04-29s: brutal kill with sasl -> child_terminated report with reason :killed" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one)
      Process.unlink(sup)
      [{_, c, _, _}] = Supervisor.which_children(sup)
      events = run("04-29s brutal kill sasl", fn -> Process.exit(c, :kill) end)
      assert Enum.any?(events, &match?(%{msg: {:report, %{label: {:supervisor, :child_terminated}, report: r}}} when is_list(r), &1))
      [r] = for %{msg: {:report, %{label: {:supervisor, :child_terminated}, report: r}}} <- events, do: r
      assert r[:reason] == :killed
      Supervisor.stop(sup)
    end

    test "04-39: with sasl, one Task crash = 1 event (no proc_lib crash report); one GenServer call crash = 2 (+ supervisor ones if supervised)" do
      {:ok, pid} = Task.start(fn -> crash(:raise) end)
      events = run("04-39 task sasl", fn -> :ok end)
      # first run red: a Task produces only its own report, no proc_lib crash report even with sasl
      assert [{Task.Supervisor, :terminating}] ==
               Enum.sort(for %{msg: {:report, %{label: l}}} <- events, do: l)
      assert Enum.all?(events, &(&1.meta.pid == pid))

      {:ok, g} = GenServer.start(Srv, %{})
      events = run("04-39b genserver sasl", fn -> catch_exit(GenServer.call(g, {:do, :raise})) end)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.meta.pid == g))
    end
  end
end
