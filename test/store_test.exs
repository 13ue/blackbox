defmodule Blackbox.StoreTest do
  use ExUnit.Case, async: false
  require Logger
  alias Blackbox.{Buffer, DB, Store, TestRepo}

  setup do
    # Discard what earlier tests left, then hold everything until a test attaches.
    Buffer.set_writer(fn _ -> :ok end)
    Buffer.drain(500)
    Buffer.set_writer(nil)
    DB.reset()
    :ok
  end

  defp issue(fp, count, n_samples) do
    %{
      fingerprint: fp,
      type: "RuntimeError",
      title: "boom",
      count: count,
      first_at: 1_000_000,
      last_at: 2_000_000,
      samples:
        for(
          i <- 1..n_samples,
          do: %{
            kind: :error,
            type: "RuntimeError",
            message: "m#{i}",
            source: "logger",
            at: 1_500_000,
            stacktrace: [],
            crumbs: []
          }
        )
    }
  end

  defp attach(opts \\ []) do
    start_supervised!({Blackbox, [repo: TestRepo, build: "b1"] ++ opts})
  end

  test "08-24: upsert by fingerprint: counts add up, one row per fingerprint, samples become occurrences" do
    batch = [issue("a", 500, 3), issue("b", 300, 3), issue("c", 200, 3)]
    :ok = Store.write(TestRepo, batch, "b1")
    :ok = Store.write(TestRepo, batch, "b2")

    assert DB.rows("SELECT fingerprint, count, builds FROM blackbox_issues ORDER BY fingerprint") ==
             [["a", 1000, ["b1", "b2"]], ["b", 600, ["b1", "b2"]], ["c", 400, ["b1", "b2"]]]

    assert DB.one("SELECT count(*) FROM blackbox_occurrences") == 18
  end

  test "payload is jsonb, written without Jason" do
    refute Code.ensure_loaded?(Jason)
    :ok = Store.write(TestRepo, [issue("j", 1, 1)], "b1")
    assert DB.one("SELECT payload->>'message' FROM blackbox_occurrences") == "m1"
  end

  test "08-25: 8 concurrent writers on one fingerprint keep an exact count" do
    1..8
    |> Task.async_stream(
      fn _ -> for _ <- 1..25, do: :ok = Store.write(TestRepo, [issue("hot", 1, 1)], "b1") end,
      max_concurrency: 8
    )
    |> Stream.run()

    assert DB.one("SELECT count FROM blackbox_issues WHERE fingerprint = 'hot'") == 200
  end

  test "keeps the last 100 occurrences per issue" do
    for _ <- 1..40, do: :ok = Store.write(TestRepo, [issue("many", 3, 3)], "b1")
    assert DB.one("SELECT count(*) FROM blackbox_occurrences") == 100
    assert DB.one("SELECT count FROM blackbox_issues") == 120
  end

  test "08-26: the database being down is an error return, under 2 s" do
    start_supervised!(Blackbox.DownRepo)
    {us, res} = :timer.tc(fn -> Store.write(Blackbox.DownRepo, [issue("x", 1, 1)], "b1") end)
    assert {:error, _} = res
    assert us < 2_000_000
  end

  test "attached, a real crash lands in Postgres with its build and node" do
    attach()
    Task.start(fn -> raise "stored boom" end)
    Process.sleep(100)
    Buffer.flush()
    Process.sleep(300)

    assert [["RuntimeError", "stored boom", 1, "b1"]] =
             DB.rows("SELECT type, title, count, last_build FROM blackbox_issues")

    assert DB.one("SELECT node FROM blackbox_occurrences") == to_string(node())

    assert DB.one("SELECT payload->'stacktrace'->0->>'in_app' FROM blackbox_occurrences") in [
             "true",
             "false"
           ]
  end

  test "the store writes on its own one-connection pool, not the host's" do
    attach()
    # Hold every connection of the host's pool.
    holders =
      for _ <- 1..5 do
        Task.async(fn -> TestRepo.transaction(fn -> Process.sleep(1_500) end) end)
      end

    Process.sleep(100)
    Logger.error("while the host pool is exhausted")
    Process.sleep(150)
    Buffer.flush()
    Process.sleep(400)
    assert DB.total() == 1
    Enum.each(holders, &Task.await/1)
  end

  test "boot: a failure before the store attaches is stored once it does" do
    Logger.error("before the store")
    Process.sleep(300)
    attach()
    Buffer.flush()
    Process.sleep(300)
    assert DB.rows("SELECT title, count FROM blackbox_issues") == [["before the store", 1]]
  end

  test "stop: what the buffer holds is in the database after the store stops" do
    attach()
    :sys.suspend(Buffer)
    for _ <- 1..50, do: Logger.error("at shutdown")
    :sys.resume(Buffer)
    stop_supervised!(Blackbox.Store)
    assert DB.rows("SELECT title, count FROM blackbox_issues") == [["at shutdown", 50]]
  end

  test "spool: what the buffer holds when it stops is in a file, and stored on the next attach" do
    dir = Path.join(System.tmp_dir!(), "blackbox_spool_#{System.unique_integer([:positive])}")
    Application.put_env(:blackbox, :spool_dir, dir)

    on_exit(fn ->
      Application.delete_env(:blackbox, :spool_dir)
      File.rm_rf(dir)
    end)

    for _ <- 1..7, do: Logger.error("spooled")
    Process.sleep(100)
    # The buffer stops as when :blackbox stops (the Repo was the failure).
    :ok = Supervisor.terminate_child(Blackbox.Supervisor, Buffer)
    assert [_] = Path.wildcard(Path.join(dir, "*.spool"))
    {:ok, _} = Supervisor.restart_child(Blackbox.Supervisor, Buffer)

    attach(spool_dir: dir)
    Buffer.flush()
    Process.sleep(300)
    assert DB.rows("SELECT title, count FROM blackbox_issues") == [["spooled", 7]]
    assert Path.wildcard(Path.join(dir, "*.spool")) == []
  end

  test "mix blackbox.gen.migration writes a migration that calls Blackbox.Migration" do
    dir = Path.join(System.tmp_dir!(), "bb_migrations_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    path = Mix.Tasks.Blackbox.Gen.Migration.run(["--migrations-path", dir])
    assert File.read!(path) =~ "Blackbox.Migration.up(version: 1)"
    assert Path.basename(path) =~ ~r/^\d{14}_add_blackbox\.exs$/
  end
end
