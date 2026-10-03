defmodule Lab05.EctoTest do
  # Ecto 3.14 / Postgrex 0.22 / DBConnection 2.10. Predictions written before the first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  alias Lab05.{Repo, Thing}
  import Ecto.Query, only: [from: 2]

  setup_all do
    start_supervised!(Repo)
    Repo.query!("truncate things")
    :ok
  end

  setup do
    C.start()
    on_exit(&C.stop/0)
    :ok
  end

  defp queries(msgs), do: C.tels(msgs, :query) |> Enum.filter(&(&1.name == [:lab05, :repo, :query]))

  test "05-37: an undefined table: {:error, Postgrex.Error}; query event carries the error; nothing at :warning or above" do
    assert {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} = Repo.query("select * from nope")
    msgs = C.collect()
    assert [%{meta: %{result: {:error, %Postgrex.Error{}}}}] = queries(msgs)
    assert C.logs(msgs, :warning) == []
    IO.puts("05-37 query event meta keys: #{inspect(Map.keys(hd(queries(msgs)).meta))}")
  end

  test "05-38: a unique violation handled by unique_constraint returns {:error, changeset}, yet the query event still carries a Postgrex.Error" do
    Repo.insert!(%Thing{name: "dup"})
    C.collect(50)
    cs = Ecto.Changeset.change(%Thing{name: "dup"}) |> Ecto.Changeset.unique_constraint(:name)
    assert {:error, %Ecto.Changeset{valid?: false}} = Repo.insert(cs)
    msgs = C.collect()
    assert [%{meta: %{result: {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}}}] = queries(msgs)
    assert C.logs(msgs, :warning) == []
    # and without the constraint declared it raises
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(%Thing{name: "dup"}) end
  end

  test "05-39: Repo.rollback: {:error, :why}; query events for begin and rollback; nothing logged" do
    assert {:error, :why} = Repo.transact(fn -> Repo.insert!(%Thing{name: "tx"}); Repo.rollback(:why) end)
    msgs = C.collect()
    qs = queries(msgs) |> Enum.map(& &1.meta.query)
    IO.puts("05-39 queries: #{inspect(qs)}")
    assert "begin" in qs
    assert "rollback" in qs
    assert C.logs(msgs, :warning) == []
  end

  test "05-40: a raise inside a transaction: rolled back, reraised to the caller, no log" do
    assert_raise RuntimeError, fn -> Repo.transact(fn -> Repo.insert!(%Thing{name: "tx2"}); raise "in tx" end) end
    msgs = C.collect()
    assert "rollback" in (queries(msgs) |> Enum.map(& &1.meta.query))
    assert C.logs(msgs, :warning) == []
    assert Repo.aggregate(from(t in Thing, where: t.name == "tx2"), :count) == 0
  end

  defp warm do
    Task.await_many(for _ <- 1..2, do: Task.async(fn -> Repo.query!("select pg_sleep(0.05)") end))
  end

  defp kill_others do
    %{rows: [[n]]} = Repo.query!("select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'lab_0031_05' and pid <> pg_backend_pid() and backend_type = 'client backend'")
    n
  end

  # first run RED: 0 logs within 1 s. An idle connection killed server-side is not noticed at once.
  # second form RED too: the next user was transparently retried (tcp send: closed); in the first run a
  # user got FATAL 57P01 raised. Both happen, depending on whether the FATAL frame was read first.
  test "05-41: pg_terminate_backend on an idle pool connection: nothing logged at once; the next checkout logs 'disconnected' and the caller gets :ok or FATAL 57P01" do
    warm()
    C.collect(50)
    1 = kill_others()
    assert C.logs(C.collect(300), :error) == []
    results = Task.await_many(for _ <- 1..2, do: Task.async(fn -> Repo.query("select pg_sleep(0.05)") end))
    msgs = C.collect(500)
    IO.puts("05-41 results=#{inspect(Enum.map(results, fn {:ok, _} -> :ok; {:error, e} -> e.__struct__ |> then(&{&1, Map.get(e, :postgres, %{})[:code]}) end))}")
    IO.puts("05-41 logs=#{inspect(Enum.map(C.logs(msgs, :error), &(C.text(&1) |> String.slice(0, 200))))}")
    assert Enum.all?(results, &match?({:ok, _}, &1) or match?({:error, %Postgrex.Error{postgres: %{code: :admin_shutdown}}}, &1))
    assert [log] = C.logs(msgs, :error)
    assert C.text(log) =~ "disconnected"
    assert C.tels(msgs, :exception) == []
  end

  test "05-41b: an idle killed connection is found by DBConnection's idle ping (idle_interval 1000 ms) within 2.5 s and logged" do
    warm()
    C.collect(50)
    1 = kill_others()
    msgs = C.collect(2500)
    IO.puts("05-41b logs=#{inspect(Enum.map(C.logs(msgs, :error), &(C.text(&1) |> String.slice(0, 200))))}")
    assert [_] = C.logs(msgs, :error)
    warm()
  end

  # first run RED: queue_target/queue_interval passed per call are ignored (they are pool start options);
  # the caller simply waited 1349 ms and succeeded. Now a dynamic repo with a 1-conn pool and a short queue.
  test "05-42: pool exhausted (pool_size 1, queue_target 50): the waiting caller gets DBConnection.ConnectionError; a query event carries it; nothing logged" do
    {:ok, pid} = Repo.start_link(name: :small_repo, pool_size: 1, queue_target: 50, queue_interval: 100)
    Process.unlink(pid)
    Repo.put_dynamic_repo(:small_repo)
    parent = self()
    holder = Task.async(fn -> Repo.put_dynamic_repo(:small_repo); Repo.transact(fn -> send(parent, :holding); Process.sleep(1000); {:ok, 1} end) end)
    assert_receive :holding
    C.collect(50)
    {t, res} = :timer.tc(fn -> Repo.query("select 1") end)
    msgs = C.collect()
    IO.puts("05-42 after #{div(t, 1000)}ms: #{inspect(res) |> String.slice(0, 220)}; query events=#{length(queries(msgs))}")
    Task.await(holder)
    Repo.put_dynamic_repo(Repo)
    Supervisor.stop(pid)
    assert {:error, %DBConnection.ConnectionError{}} = res
    assert [%{meta: %{result: {:error, %DBConnection.ConnectionError{}}}}] = queries(msgs)
    assert C.logs(msgs, :warning) == []
  end

  test "05-43: a client timeout (pg_sleep 1 with timeout: 100): error to the caller AND one :error log from the connection pid naming the client pid" do
    me = self()
    res = Repo.query("select pg_sleep(1)", [], timeout: 100)
    msgs = C.collect(500)
    logs = C.logs(msgs, :error)
    IO.puts("05-43 res=#{inspect(res) |> String.slice(0, 200)}")
    IO.puts("05-43 logs=#{inspect(Enum.map(logs, &(C.text(&1) |> String.slice(0, 300))))}")
    # first run RED: the caller gets Postgrex query_canceled (Postgrex cancels the statement), not a ConnectionError
    assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} = res
    assert [log] = logs
    assert log.from != me
    assert C.text(log) =~ inspect(me)
  end

  test "05-44: database unreachable: DBConnection logs connect failures at :error on every backoff, no telemetry" do
    {:ok, pid} = Repo.start_link(name: :down_repo, port: 1, pool_size: 1, backoff_min: 100, backoff_max: 100)
    Process.unlink(pid)
    msgs = C.collect_for(1000)
    Supervisor.stop(pid)
    logs = C.logs(msgs, :error)
    IO.puts("05-44 connect failures in ~1s: #{length(logs)}; first: #{logs |> Enum.take(1) |> Enum.map(&(C.text(&1) |> String.slice(0, 200))) |> inspect()}")
    assert length(logs) >= 1
    assert C.tels(msgs, :exception) == []
  end
end
