defmodule Blackbox.SecretsTest do
  # ADR section 5: known secrets through every path, and none reaches the
  # database, the spool or a process dictionary. Each run uses fresh secrets.
  use ExUnit.Case, async: false
  require Logger
  alias Blackbox.{Buffer, DB, TestRepo}

  defmodule Server do
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call({:boom, _}, _, _), do: raise("boom")
    def handle_call({:apply, _}, _, s), do: {:noreply, s}
    def handle_cast({:set, kv}, s), do: {:noreply, Map.merge(s, kv)}

    # The host's job for positional content: OTP applies this to the report.
    def format_status(status),
      do:
        Map.update(status, :message, nil, fn
          {tag, _} -> {tag, :redacted}
          m -> m
        end)
  end

  defp secret, do: "S3CR3T" <> Base.encode16(:crypto.strong_rand_bytes(6))

  defp wait_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 2000
  end

  defp run_in_task(fun) do
    {:ok, pid} = Task.start(fun)
    wait_down(pid)
  end

  setup do
    Buffer.set_writer(fn _ -> :ok end)
    Buffer.drain(500)
    Buffer.set_writer(nil)
    DB.reset()
    start_supervised!({Blackbox, repo: TestRepo, build: "b1"})
    TestRepo.query!("CREATE TABLE IF NOT EXISTS secret_spaces (name text UNIQUE)")
    TestRepo.query!("DELETE FROM secret_spaces")
    :ok
  end

  defp stored do
    Buffer.flush()
    Process.sleep(400)
    Buffer.flush()
    Process.sleep(200)

    DB.one("""
    SELECT coalesce(string_agg(t, ' '), '') FROM (
      SELECT title AS t FROM blackbox_issues
      UNION ALL SELECT message || ' ' || payload::text FROM blackbox_occurrences) x
    """)
  end

  test "secrets through every path never reach the database" do
    for _round <- 1..3 do
      s = for i <- 1..15, into: %{}, do: {i, secret()}

      # 1. state under a secret key; 2. positional call message, through format_status
      {:ok, g} = GenServer.start(Server, %{token: s[1], board: "ok"})
      GenServer.cast(g, {:set, %{password: s[3]}})
      :sys.log(g, true)
      GenServer.cast(g, {:set, %{api_key: s[4]}})
      catch_exit(GenServer.call(g, {:boom, s[2]}))

      # 5. a call message inside an exit reason (a timeout)
      {:ok, h} = GenServer.start(Server, %{})
      run_in_task(fn -> GenServer.call(h, {:apply, s[5]}, 10) end)

      # 15. a callee's function_clause, nested in the caller's exit with its arguments
      {:ok, k} = GenServer.start(Server, %{})
      run_in_task(fn -> GenServer.call(k, {:unknown, s[15]}) end)

      # 6. KeyError, 7. MatchError, 8. FunctionClauseError: values in exceptions
      run_in_task(fn -> Map.fetch!(%{name: s[6]}, :missing) end)
      run_in_task(fn -> {:ok, _} = Function.identity({:error, s[7]}) end)
      run_in_task(fn -> Blackbox.Fixtures.Sites.only_ok({:error, s[8]}) end)

      # 9. Postgrex: Key (name)=(...) in the detail
      TestRepo.query!("INSERT INTO secret_spaces VALUES ($1)", [s[9]])
      run_in_task(fn -> TestRepo.query!("INSERT INTO secret_spaces VALUES ($1)", [s[9]]) end)

      # 10. an exception message and a log line with key=value and a path
      run_in_task(fn -> raise ArgumentError, "bad token=#{s[10]}" end)
      Logger.error("GET /b/#{s[11]}/tabs?key=#{s[12]} failed")

      # 13. crumbs (text and data) and 14. context, carried by a crash
      run_in_task(fn ->
        Logger.info("loading /b/#{s[13]}")
        Blackbox.crumb("saved", %{password: s[13]})
        Blackbox.set_context(%{api_key: s[14]})
        raise "with crumbs"
      end)

      text = stored()
      leaked = for {i, v} <- s, String.contains?(text, v), do: i
      assert leaked == [], "secrets #{inspect(leaked)} reached the database"
      assert text =~ "[Filtered]"
      DB.reset()
    end
  end

  test "a process dictionary never holds a secret crumb" do
    s = secret()
    me = self()

    pid =
      spawn(fn ->
        Logger.info("GET /b/#{s}?key=#{s}")
        Blackbox.crumb("x", %{token: s})
        send(me, :ready)
        Process.sleep(:infinity)
      end)

    assert_receive :ready
    {:dictionary, dict} = Process.info(pid, :dictionary)
    refute inspect(dict, limit: :infinity, printable_limit: :infinity) =~ s
    Process.exit(pid, :kill)
  end

  test "the spool holds no secret" do
    s = secret()
    dir = Path.join(System.tmp_dir!(), "bb_secret_spool_#{System.unique_integer([:positive])}")
    Application.put_env(:blackbox, :spool_dir, dir)

    on_exit(fn ->
      Application.delete_env(:blackbox, :spool_dir)
      File.rm_rf(dir)
    end)

    stop_supervised!(Blackbox.Store)

    Logger.error("GET /b/#{s} failed", [])
    {:ok, g} = GenServer.start(Server, %{token: s})
    catch_exit(GenServer.call(g, {:boom, s}))
    Process.sleep(100)
    :ok = Supervisor.terminate_child(Blackbox.Supervisor, Buffer)
    {:ok, _} = Supervisor.restart_child(Blackbox.Supervisor, Buffer)
    [file] = Path.wildcard(Path.join(dir, "*.spool"))
    refute File.read!(file) =~ s

    refute inspect(:erlang.binary_to_term(File.read!(file)),
             limit: :infinity,
             printable_limit: :infinity
           ) =~ s
  end
end
