defmodule BeamLab.RoutesTest do
  use BeamLab.Case
  alias BeamLab.{Srv, Sasl}

  defp spy(_) do
    :ok = :logger.add_primary_filter(:lab_spy, {&BeamLab.PrimarySpy.filter/2, %{to: self()}})
    on_exit(fn -> :logger.remove_primary_filter(:lab_spy) end)
  end

  # {events the primary spy saw, events the handler saw}
  defp both(name, fun) do
    handler = run(name, fun)
    primary = drain_primary([])
    {primary, handler}
  end

  defp drain_primary(acc) do
    receive do
      {:primary, e} -> drain_primary([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp labels(events), do: for(%{msg: {:report, %{label: l}}} <- events, do: l)

  describe "04-70: where Process.get looks (relay from 02)" do
    test "04-70: gen_server/proc_lib/Task reports: the handler sees the dying process's dictionary; plain spawn: it does not" do
      {:ok, pid} = GenServer.start(BeamLab.MarkedSrv, :srv_marker)
      [e] = run("04-70a dict genserver", fn -> GenServer.cast(pid, :raise) end)
      assert e.handler_pid == pid
      assert e.handler_dict_marker == :srv_marker

      Task.start(fn -> Process.put(:lab_marker, :task_marker); crash(:raise) end)
      [t] = run("04-70b dict task", fn -> :ok end)
      assert t.handler_dict_marker == :task_marker

      spawn(fn -> Process.put(:lab_marker, :plain_marker); crash(:raise) end)
      [p] = run("04-70c dict plain", fn -> :ok end)
      assert p.handler_dict_marker == nil

      Sasl.set(true)
      try do
        {:ok, pid} = GenServer.start(BeamLab.MarkedSrv, :sasl_marker)
        events = run("04-70d dict proc_lib crash", fn -> GenServer.cast(pid, :raise) end)
        crash = Enum.find(events, &match?(%{msg: {:report, %{label: {:proc_lib, :crash}}}}, &1))
        assert crash.handler_pid == pid
        assert crash.handler_dict_marker == :sasl_marker
      after
        Sasl.set(false)
      end
    end
  end

  describe "dropped by the primary filter vs never emitted (relay from 01)" do
    setup :spy

    test "04-71: add_primary_filter PREPENDS, so our filter runs before Elixir's translator" do
      assert [{:lab_spy, _}, {:logger_translator, _} | _] = :logger.get_primary_config().filters
    end

    test "04-72: GenServer.start init raise: emitted (proc_lib crash report), dropped by the translator" do
      {primary, handler} = both("04-72 init raise", fn -> GenServer.start(Srv, :raise) end)
      assert labels(primary) == [{:proc_lib, :crash}]
      assert handler == []
    end

    test "04-73: bare spawn exit(:boom): never emitted" do
      {primary, handler} = both("04-73 spawn exit", fn -> spawn(fn -> exit(:boom) end) end)
      assert primary == []
      assert handler == []
    end

    test "04-74: linked Task caller dying with its task: only the task is emitted; the caller's death never is" do
      caller = spawn(fn -> Task.async(fn -> crash(:raise) end) |> Task.await() end)
      {primary, handler} = both("04-74 linked caller", fn -> :ok end)
      assert labels(primary) == [{Task.Supervisor, :terminating}]
      assert length(handler) == 1
      refute Enum.any?(primary, &(&1.meta.pid == caller))
    end

    test "04-75: supervisor restart, start error and max-intensity shutdown: all emitted, all [:otp, :sasl] ones dropped" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one, max_restarts: 0)
      Process.unlink(sup)
      [{_, c, _, _}] = Supervisor.which_children(sup)
      {primary, handler} = both("04-75a restart/give up", fn -> GenServer.cast(c, {:do, :raise}) end)
      assert {:supervisor, :child_terminated} in labels(primary)
      assert {:supervisor, :shutdown} in labels(primary)
      assert labels(handler) == [{:gen_server, :terminate}]

      {primary, handler} =
        both("04-75b start error", fn ->
          Process.flag(:trap_exit, true)
          {:error, _} = Supervisor.start_link([%{id: :x, start: {Srv, :start_link, [:raise]}}], strategy: :one_for_one)
        end)
      assert {:supervisor, :start_error} in labels(primary)
      assert {:proc_lib, :crash} in labels(primary)
      assert handler == []
    end
  end

  describe "ways to get them without printing them (relay from 01)" do
    test "04-76: route A: translator sasl: true + a domain filter on the console handler: we get them, the console does not" do
      # a stand-in console: a second capture handler that forwards to its own collector process
      me = self()
      collector = spawn(fn -> collect_loop(me, []) end)
      console = BeamLab.Capture.attach(collector)
      :ok = :logger.add_handler_filter(console, :no_sasl, {&:logger_filters.domain/2, {:stop, :sub, [:otp, :sasl]}})
      Sasl.set(true)
      try do
        {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one)
        Process.unlink(sup)
        [{_, c, _, _}] = Supervisor.which_children(sup)
        BeamLab.Capture.collect(50)
        send(collector, :reset)
        ours = run("04-76 route A", fn -> GenServer.cast(c, {:do, :raise}) end)
        send(collector, {:get, self()})
        console_events = receive do: ({:collected, es} -> es)
        # first run red (harness: both handlers sent to the test pid); now split per handler
        assert labels(ours) |> Enum.sort() ==
                 Enum.sort([{:gen_server, :terminate}, {:proc_lib, :crash}, {:supervisor, :child_terminated}, {:supervisor, :progress}])
        assert labels(console_events) == [{:gen_server, :terminate}]
        Supervisor.stop(sup)
      after
        Sasl.set(false)
        :logger.remove_handler(console)
      end
    end

    test "04-77: route B: our primary filter before the translator sees sasl reports while every handler (console incl.) sees none" do
      spy(nil)
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one)
      Process.unlink(sup)
      [{_, c, _, _}] = Supervisor.which_children(sup)
      {primary, handler} = both("04-77 route B", fn -> GenServer.cast(c, {:do, :kill_me}) end)
      assert {:supervisor, :child_terminated} in labels(primary)
      assert Enum.all?(handler, &(&1.meta[:domain] != [:otp, :sasl]))
      Supervisor.stop(sup)
    end

    test "04-78: route D: a monitor sees the :killed that logger never reports" do
      {:ok, sup} = Supervisor.start_link([{Srv, %{}}], strategy: :one_for_one)
      Process.unlink(sup)
      [{_, c, _, _}] = Supervisor.which_children(sup)
      ref = Process.monitor(c)
      assert run("04-78 monitor", fn -> Process.exit(c, :kill) end) == []
      assert_received {:DOWN, ^ref, :process, ^c, :killed}
      Supervisor.stop(sup)
    end
  end

  describe "telemetry handler failure (relay from lead)" do
    test "04-79: a raising :telemetry handler is detached, a [:telemetry, :handler, :failure] event fires, and an :error log (domain [:telemetry]) reaches :logger" do
      me = self()
      :telemetry.attach(:lab_fail_watch, [:telemetry, :handler, :failure], fn _, _, m, _ -> send(me, {:failure, m}) end, nil)
      :telemetry.attach(:lab_bad, [:lab, :ev], fn _, _, _, _ -> raise "telemetry boom" end, nil)
      events = run("04-79 telemetry", fn -> :telemetry.execute([:lab, :ev], %{}, %{}) end)
      :telemetry.detach(:lab_fail_watch)
      assert :telemetry.list_handlers([:lab, :ev]) == []
      assert_received {:failure, %{handler_id: :lab_bad, kind: :error, reason: %RuntimeError{}}}
      # first run red: :telemetry.attach itself logs an :info report per attach (domain [:telemetry])
      assert [%{level: :info}, %{level: :info}, e] = events
      assert e.level == :error
      assert e.meta.domain == [:telemetry]
    end
  end

  defp collect_loop(me, acc) do
    receive do
      :reset -> collect_loop(me, [])
      {:get, to} -> send(to, {:collected, Enum.reverse(acc)}); collect_loop(me, acc)
      {:log_event, e, _} -> collect_loop(me, [e | acc])
    end
  end
end
