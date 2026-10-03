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
end
