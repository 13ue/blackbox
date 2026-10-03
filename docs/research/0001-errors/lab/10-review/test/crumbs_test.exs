defmodule Spike.CrumbsTest do
  use ExUnit.Case, async: false
  require Logger

  defmodule Gs do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_call(:boom, _, s) do
      Spike.crumb("loaded order")
      raise "gs crumb boom"
    end
  end

  setup do
    Spike.Buffer.set_writer(Spike.Sink.to(self()))
    Spike.Sink.collect(50)
    :ok
  end

  defp sample(msg) do
    [i] = Enum.filter(Spike.Sink.collect(), &(hd(&1.samples).message == msg))
    hd(i.samples)
  end

  test "08-19: manual crumbs in a Task arrive with its crash, in order, only the last 20" do
    Task.start(fn ->
      for n <- 1..50, do: Spike.crumb("step #{n}")
      raise "crumb boom"
    end)
    s = sample("crumb boom")
    assert Enum.map(s.crumbs, & &1.message) == for(n <- 31..50, do: "step #{n}")
  end

  test "08-20: Logger.info and Logger.debug in the process become crumbs by themselves" do
    Task.start(fn ->
      Logger.debug("fetched user 5")
      Logger.info("charging card")
      raise "logger crumb boom"
    end)
    assert Enum.map(sample("logger crumb boom").crumbs, & &1.message) == ["fetched user 5", "charging card"]
  end

  test "08-21: a Task crash carries the crumbs of its caller (the request) through $callers" do
    Spike.crumb("GET /boards/1")
    Task.start(fn -> raise "child boom" end)
    s = sample("child boom")
    assert Enum.map(s.caller_crumbs, & &1.message) == ["GET /boards/1"]
  end

  test "08-22: a GenServer crash carries the crumbs recorded inside the callback" do
    {:ok, g} = GenServer.start(Gs, %{})
    catch_exit(GenServer.call(g, :boom))
    assert Enum.map(sample("gs crumb boom").crumbs, & &1.message) == ["loaded order"]
  end

  test "08-23: a plain spawn crash carries no crumbs (the handler runs in :logger_proxy, the process is gone)" do
    spawn(fn -> Spike.crumb("lost"); raise "spawn crumb boom" end)
    assert sample("spawn crumb boom").crumbs == []
  end
end
