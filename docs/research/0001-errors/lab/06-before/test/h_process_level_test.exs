defmodule BeforeLab.ProcessLevelTest do
  use ExUnit.Case, async: false
  require Logger
  alias BeforeLab.{Capture, Ring}

  setup do
    prev = :logger.get_primary_config().level
    on_exit(fn -> :logger.set_primary_config(:level, prev); :logger.remove_handler(:cap) end)
    :ok
  end

  test "06-47: Logger.put_process_level can only RAISE a process's threshold; it cannot open debug under primary :info" do
    # first run (red): expected the sampled process to log debug. Truth: the process level is a primary FILTER
    # (Logger.Utils.process_level/2) that can only :stop events, and the primary level gates before it.
    :logger.set_primary_config(:level, :info)
    Capture.attach(:cap, :all, self())
    Task.async(fn -> Logger.put_process_level(self(), :debug); Logger.debug("sampled") end) |> Task.await()
    assert flush() == []
    # the reverse works: primary :debug, one process muted to :info
    :logger.set_primary_config(:level, :debug)
    Task.async(fn -> Logger.put_process_level(self(), :info); Logger.debug("muted") end) |> Task.await()
    Task.async(fn -> Logger.debug("loud") end) |> Task.await()
    msgs = for {:logged, %{msg: {:string, s}}, _, _} <- flush(), do: IO.iodata_to_binary(s)
    assert msgs == ["loud"]
  end

  test "06-48: ETS ring rows outlive their process (a leak without a monitor/sweeper)" do
    Ring.Ets.new()
    t = Task.async(fn -> for i <- 1..10, do: Ring.Ets.add(i); self() end)
    pid = Task.await(t)
    refute Process.alive?(pid)
    assert Ring.Ets.read(pid) == Enum.to_list(1..10)
    Ring.Ets.delete(pid)
    assert Ring.Ets.read(pid) == []
  end

  defp flush(acc \\ []) do
    receive do
      m -> flush([m | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
