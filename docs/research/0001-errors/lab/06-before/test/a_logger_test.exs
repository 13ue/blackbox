defmodule BeforeLab.LoggerTest do
  use ExUnit.Case, async: false
  require Logger
  alias BeforeLab.{Capture, CrumbHandler, Ring}

  setup do
    prev = :logger.get_primary_config().level
    on_exit(fn ->
      :logger.set_primary_config(:level, prev)
      for id <- [:cap_a, :cap_b, :crumbs], do: :logger.remove_handler(id)
      :logger.unset_module_level()
    end)
    Ring.Pdict.clear()
    :ok
  end

  defp drain(acc \\ []) do
    receive do
      {:logged, e, _, _} -> drain([e | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  test "06-1: primary level :info drops Logger.debug before any handler, even one at level :all" do
    :logger.set_primary_config(:level, :info)
    Capture.attach(:cap_a, :all, self())
    Logger.debug("below")
    Logger.info("above")
    msgs = for %{msg: {:string, s}} <- drain(), do: IO.iodata_to_binary(s)
    assert msgs == ["above"]
  end

  test "06-2: primary :debug + console-like handler at :info + crumb handler at :all: only the crumb handler sees debug" do
    :logger.set_primary_config(:level, :debug)
    Capture.attach(:cap_a, :info, self())
    Capture.attach(:cap_b, :all, self())
    Logger.debug("d")
    events = drain()
    # one debug event, delivered once (to cap_b only)
    assert length(events) == 1
    assert hd(events).level == :debug
  end

  test "06-3: the handler runs in the process that called Logger" do
    :logger.set_primary_config(:level, :debug)
    Capture.attach(:cap_a, :all, self())
    task = Task.async(fn -> Logger.debug("from task"); self() end)
    tpid = Task.await(task)
    assert_receive {:logged, _, ^tpid, _}
  end

  test "06-4: Logger.debug arguments are not evaluated when the level is off" do
    :logger.set_primary_config(:level, :info)
    Logger.debug(send(self(), :evaluated))
    refute_received :evaluated
  end

  test "06-5: a module level lets one module emit debug while primary stays :info" do
    :logger.set_primary_config(:level, :info)
    Capture.attach(:cap_a, :all, self())
    Logger.put_module_level(__MODULE__, :debug)
    Logger.debug("module debug")
    assert [%{level: :debug}] = drain()
  end

  test "06-6: a crumb handler at :all fills the caller's own pdict ring (per process, no shared state)" do
    :logger.set_primary_config(:level, :debug)
    :ok = :logger.add_handler(:crumbs, CrumbHandler, %{level: :all})
    Logger.debug("step 1")
    Logger.info("step 2")
    other = Task.async(fn -> Logger.debug("other"); Ring.Pdict.read() end) |> Task.await()
    mine = Ring.Pdict.read()
    assert Enum.map(mine, fn {_, l, m} -> {l, IO.iodata_to_binary(m)} end) == [debug: "step 1", info: "step 2"]
    assert [{_, :debug, "other"}] = other
  end

  test "06-7: the ring keeps only the newest 50 crumbs" do
    for i <- 1..500, do: Ring.Pdict.add(i)
    assert Ring.Pdict.read() == Enum.to_list(451..500)
  end
end
