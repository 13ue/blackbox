defmodule Blackbox.CrumbsTest do
  use ExUnit.Case, async: false
  require Logger
  alias Blackbox.{Crumbs, Sink}
  alias Blackbox.Fixtures.Gs

  setup do
    Sink.attach()
    Sink.collect(50)
    :ok
  end

  defp sample(title) do
    assert [i] = Enum.filter(Sink.collect(), &(&1.title == title))
    hd(i.samples)
  end

  defp messages(crumbs), do: Enum.map(crumbs, & &1.message)

  test "08-19: crumbs in a Task arrive with its crash, in order, the last 50" do
    Task.start(fn ->
      for n <- 1..120, do: Blackbox.crumb("step #{n}")
      raise "crumb boom"
    end)

    assert messages(sample("crumb boom").crumbs) == for(n <- 71..120, do: "step #{n}")
  end

  test "08-20: Logger.info and Logger.debug in the process become crumbs by themselves" do
    Task.start(fn ->
      Logger.debug("fetched user 5")
      Logger.info("charging card")
      raise "logger crumb boom"
    end)

    assert messages(sample("logger crumb boom").crumbs) == ["fetched user 5", "charging card"]
  end

  test "08-21: a Task crash carries its caller's crumbs through $callers" do
    Blackbox.crumb("GET /boards/1")
    Task.start(fn -> raise "child boom" end)
    assert messages(sample("child boom").caller_crumbs) == ["GET /boards/1"]
  end

  test "a GenServer crash in a call carries the caller's crumbs through client_info" do
    Blackbox.crumb("before the call")
    {:ok, g} = Gs.start(%{})
    catch_exit(GenServer.call(g, :crumbs))
    s = sample("gs crumb boom")
    assert messages(s.crumbs) == ["loaded order"]
    assert messages(s.caller_crumbs) == ["before the call"]
  end

  test "08-23: a plain spawn crash carries no crumbs (the handler runs in :logger_proxy)" do
    spawn(fn ->
      Blackbox.crumb("lost")
      raise "spawn crumb boom"
    end)

    assert sample("spawn crumb boom").crumbs == []
  end

  test "M7: the ring stays bounded however much is added" do
    big = String.duplicate("x", 10_000)

    bound =
      Task.async(fn ->
        for _ <- 1..1_000, do: Crumbs.add(:info, {:string, big})
        :erts_debug.flat_size(Process.get(Crumbs.key()))
      end)
      |> Task.await()

    # 100 entries at most, each a capped 200-byte binary: about 15 KB.
    assert bound * 8 < 2 * Crumbs.cap() * 300
  end

  test "10-10: a crumb of a slice does not keep the big binary alive" do
    me = self()

    spawn(fn ->
      big = :crypto.strong_rand_bytes(4_000_000)
      Logger.info(binary_part(big, 0, 100))
      _ = big
      :erlang.garbage_collect()
      {:binary, bins} = Process.info(self(), :binary)
      send(me, {:bins, Enum.map(bins, fn {_, size, _} -> size end)})
    end)

    assert_receive {:bins, sizes}, 1000
    refute 4_000_000 in sizes
  end

  defp in_task(fun) do
    {:ok, pid} = Task.start(fun)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 1000
  end

  test "06-42: a new request on a keep-alive connection resets the ring" do
    in_task(fn ->
      Blackbox.crumb("request 1")
      :telemetry.execute([:bandit, :request, :start], %{}, %{})
      Blackbox.crumb("request 2")
      raise "in request 2"
    end)

    assert messages(sample("in request 2").crumbs) == ["request 2"]
  end

  test "telemetry crumbs: the request line (path scrubbed), the route, HTTP calls" do
    in_task(fn ->
      conn = %{method: "GET", request_path: "/b/private-board"}
      :telemetry.execute([:phoenix, :endpoint, :start], %{}, %{conn: conn})

      :telemetry.execute([:phoenix, :router_dispatch, :start], %{}, %{
        route: "/b/:id",
        plug: MyAppWeb.BoardController,
        plug_opts: :show
      })

      req = %{method: "POST", host: "api.example.com", path: "/v1"}

      :telemetry.execute(
        [:finch, :request, :stop],
        %{duration: System.convert_time_unit(12, :millisecond, :native)},
        %{request: req, result: {:ok, %{status: 502}}}
      )

      raise "after crumbs"
    end)

    assert messages(sample("after crumbs").crumbs) ==
             [
               "GET /b/[Filtered]",
               "/b/:id MyAppWeb.BoardController.show",
               "POST api.example.com 502 12.0 ms"
             ]
  end

  test "Ecto query crumbs: source, result and time, never the SQL or params" do
    start_supervised!({Blackbox, repo: Blackbox.TestRepo, build: "b1"})
    Sink.attach()

    in_task(fn ->
      Blackbox.TestRepo.query!("SELECT $1::text", ["private-param"])
      raise "after a query"
    end)

    [crumb] = sample("after a query").crumbs
    assert crumb.message =~ ~r/^query - ok \d+\.\d ms$/
  end

  test "the store's own queries leave no crumbs and no events" do
    start_supervised!({Blackbox, repo: Blackbox.TestRepo, build: "b1"})
    Blackbox.DB.reset()
    Logger.error("one")
    Process.sleep(300)
    Blackbox.Buffer.flush()
    Process.sleep(300)
    assert Blackbox.DB.rows("SELECT title FROM blackbox_issues") == [["one"]]
  end

  test "context set in the request reaches a Task's crash through $callers" do
    Blackbox.set_context(%{route: "/boards"})
    on_exit(fn -> Process.delete(:blackbox_context) end)

    in_task(fn ->
      Blackbox.set_context(%{job: 7})
      raise "with context"
    end)

    assert sample("with context").context == %{"job" => "7", "route" => ~s("/boards")}
  end

  test "the system snapshot at the moment of failure" do
    in_task(fn -> raise "snapshot" end)
    sys = sample("snapshot").system
    assert sys.process_count > 0 and sys.process_limit > sys.process_count
    assert is_integer(sys.run_queue) and is_integer(sys.message_queue_len)
    assert sys.memory.total > 0
  end
end
