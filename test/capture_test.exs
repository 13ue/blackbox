defmodule Blackbox.CaptureTest do
  # Lab 04's failure table, one test per row: what Blackbox captures for each
  # way a process can fail, under Elixir's default Logger config.
  use ExUnit.Case, async: false
  require Logger
  alias Blackbox.Fixtures.{Gs, Statem}
  alias Blackbox.Sink

  setup do
    Sink.attach()
    Sink.collect(50)
    :ok
  end

  defp one(issues, type) do
    assert [i] = Enum.filter(issues, &(&1.type == type)), inspect(Sink.types(issues))
    i
  end

  defp wait_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 1000
  end

  describe "captured once" do
    test "a raise in a plain spawn: type, message, stack, pid" do
      pid = spawn(fn -> raise "plain boom" end)
      i = Sink.collect() |> one("RuntimeError")
      assert i.count == 1
      [s] = i.samples
      assert s.message == "plain boom" and s.pid == inspect(pid)
      assert [_ | _] = s.stacktrace
    end

    test "a Task raise carries $callers and the process label" do
      me = self()

      Task.start(fn ->
        Process.set_label({:job, 7})
        raise KeyError, "task boom"
      end)

      [s] = (Sink.collect() |> one("KeyError")).samples
      assert s.callers == [inspect(me)]
      assert s.process_label == "{:job, 7}"
    end

    test "a GenServer call raise: one event with last message, state and the app frame on top" do
      {:ok, g} = Gs.start(%{some_state: 42})
      catch_exit(GenServer.call(g, :raise))
      i = Sink.collect() |> one("ArgumentError")
      assert i.count == 1
      [s] = i.samples
      assert s.locals.last_message == ":raise"
      assert s.locals.state =~ "some_state"
      assert hd(s.stacktrace).text =~ "Gs.handle_call/3"
      assert hd(s.stacktrace).in_app
    end

    test "a GenServer cast raise" do
      {:ok, g} = Gs.start(%{})
      GenServer.cast(g, :raise)
      wait_down(g)
      assert Sink.types(Sink.collect()) == [{"RuntimeError", 1}]
    end

    test "a GenServer init raise (a [:otp, :sasl] report the translator stops)" do
      assert {:error, _} = Gs.start(:raise)
      assert Sink.types(Sink.collect()) == [{"RuntimeError", 1}]
    end

    test "a gen_statem raise" do
      {:ok, p} = Statem.start()
      catch_exit(:gen_statem.call(p, :raise))
      assert Sink.types(Sink.collect()) == [{"RuntimeError", 1}]
    end

    test "a :proc_lib.spawn raise (dropped by Elixir's translator, taken by our filter)" do
      :proc_lib.spawn(fn -> raise "proc_lib boom" end)
      assert Sink.types(Sink.collect()) == [{"RuntimeError", 1}]
    end

    test "a GenServer call exit is kind exit, grouped by shape" do
      {:ok, g} = Gs.start(%{})
      catch_exit(GenServer.call(g, :exit))
      assert Sink.types(Sink.collect()) == [{"exit :call_exit", 1}]
    end

    test "an Erlang error in a callback is the Elixir exception" do
      {:ok, g} = Gs.start(:not_a_binary)
      catch_exit(GenServer.call(g, :badarg))
      assert Sink.types(Sink.collect()) == [{"ArgumentError", 1}]
    end

    test "a throw and an exit in Tasks are kinds of their own" do
      Task.start(fn -> throw(:ball) end)
      Task.start(fn -> exit({:shutdown_like, :oops}) end)
      assert Sink.types(Sink.collect()) == [{"exit {:shutdown_like, _}", 1}, {"throw", 1}]
    end

    test "Logger.error without a crash is a :log event" do
      Logger.error("payment 991 failed")
      [s] = (Sink.collect() |> one("log")).samples
      assert s.message == "payment 991 failed"
    end

    test "a report with a label Elixir does not know (its translator drops it, 08-17b)" do
      :logger.log(:error, %{label: :my_lib_report, detail: 1}, %{})
      assert Sink.types(Sink.collect()) == [{"log", 1}]
    end

    test "a temporary application's exit, logged at :notice" do
      spec = [
        description: ~c"t",
        vsn: ~c"1",
        modules: [],
        registered: [],
        applications: [:kernel, :stdlib],
        mod: {Blackbox.CaptureTest.App, []}
      ]

      :ok = :application.load({:application, :bbx_test_app, spec})
      on_exit(fn -> :application.unload(:bbx_test_app) end)
      {:ok, _} = Application.ensure_all_started(:bbx_test_app, :temporary)
      Process.sleep(100)
      assert {"exit {:app_died, _}", 1} in Sink.types(Sink.collect())
    end
  end

  describe "supervision" do
    defp sup(child_opts, sup_opts \\ []) do
      Process.flag(:trap_exit, true)
      {:ok, sup} = Supervisor.start_link([child_opts], [strategy: :one_for_one] ++ sup_opts)
      on_exit(fn -> Process.exit(sup, :kill) end)
      sup
    end

    defp gs(name), do: %{id: name, start: {Gs, :start_link, [%{}, [name: name]]}}

    test "a supervised GenServer raise is one event (the child_terminated report is the same failure)" do
      sup(gs(:sup_gs))
      catch_exit(GenServer.call(:sup_gs, :raise))
      assert Sink.types(Sink.collect()) == [{"ArgumentError", 1}]
    end

    test "a supervised GenServer exit is one event (its child_terminated carries a bare reason)" do
      sup(gs(:sup_gs_exit))
      catch_exit(GenServer.call(:sup_gs_exit, :exit))
      assert Sink.types(Sink.collect()) == [{"exit :call_exit", 1}]
    end

    test "a brutal kill of a supervised child: the supervisor is the only witness" do
      sup(gs(:sup_gs_kill))
      Process.exit(Process.whereis(:sup_gs_kill), :kill)
      [i] = Sink.collect()
      assert i.type == "exit :killed"
      assert hd(i.samples).process_label == "{:child, :sup_gs_kill}"
    end

    test "a supervisor giving up is its own issue, besides the child crashes" do
      sup = sup(gs(:sup_gs_give_up), max_restarts: 1, max_seconds: 5)

      Enum.find(1..10, fn _ ->
        catch_exit(GenServer.call(:sup_gs_give_up, :raise))
        Process.sleep(20)
        not Process.alive?(sup)
      end)

      assert Sink.types(Sink.collect()) == [
               {"ArgumentError", 2},
               {"exit :reached_max_restart_intensity", 1}
             ]
    end

    test "a child failing in init under a supervisor is one event" do
      Process.flag(:trap_exit, true)

      assert {:error, _} =
               Supervisor.start_link([%{id: :bad, start: {Gs, :start_link, [:raise]}}],
                 strategy: :one_for_one
               )

      assert Sink.types(Sink.collect()) == [{"RuntimeError", 1}]
    end
  end

  test "call timeouts with different arguments and pids are one issue (Sentry #933)" do
    for arg <- [1, 2, 3] do
      g = spawn(fn -> Process.sleep(:infinity) end)
      Task.start(fn -> GenServer.call(g, {:slow, arg, make_ref()}, 1) end)
    end

    assert [%{type: "exit {:timeout, _}", count: 3}] = Sink.collect(400)
  end

  describe "still invisible, and said so" do
    test "exit/1 in a plain spawn" do
      spawn(fn -> exit(:boom) end)
      assert Sink.collect() == []
    end

    test "a kill of an unsupervised process" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      Process.exit(pid, :kill)
      assert Sink.collect() == []
    end

    test "a rescued exception" do
      try do
        raise "swallowed"
      rescue
        _ -> :ok
      end

      assert Sink.collect() == []
    end
  end
end

defmodule Blackbox.CaptureTest.App do
  use Application

  def start(_, _) do
    pid =
      spawn_link(fn ->
        receive do: (:never -> :ok), after: (20 -> exit({:app_died, :on_purpose}))
      end)

    {:ok, pid}
  end
end
