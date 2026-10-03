defmodule BeamLab.HandlerSafetyTest do
  use BeamLab.Case
  import ExUnit.CaptureIO
  require Logger

  @moduletag timeout: 300_000
  @log Path.expand("../../../logs/04-flood.log", __DIR__)

  defp add(id, mode) do
    :ok = :logger.add_handler(id, BeamLab.BadHandler, %{level: :all, config: %{mode: mode}})
    on_exit(fn -> :logger.remove_handler(id) end)
  end

  test "04-60: a handler that raises / exits / throws is removed by :logger; the event still reaches other handlers; the caller is unaffected" do
    for mode <- [:raise, :exit, :throw] do
      id = :"bad_#{mode}"
      add(id, mode)
      err = capture_io(:standard_error, fn ->
        out = capture_io(fn -> assert Logger.error("trigger #{mode}") == :ok end)
        send(self(), {:stdout, out})
      end)
      assert_received {:stdout, out}
      File.write!(@log, "04-60 #{mode} stderr=#{inspect(err)} stdout=#{inspect(out)}\n", [:append])
      refute id in :logger.get_handler_ids()
      events = BeamLab.Capture.collect(100)
      assert Enum.any?(events, &match?(%{msg: {:string, "trigger " <> _}}, &1))
      # first run red: other handlers DO get told, but only at :debug with internal_log_event: true
      assert [rm] = Enum.filter(events, &match?(%{msg: {:report, [logger: :removed_failing_handler] ++ _}}, &1))
      assert rm.level == :debug
      assert rm.meta.internal_log_event
      assert {:report, r} = rm.msg
      assert {_class, _reason, _stack} = r[:reason]
    end
  end

  test "04-63: handlers run in the caller: a 20 ms handler makes Logger.error take >= 20 ms in the caller" do
    add(:slow, {:sleep, 20})
    {us, :ok} = :timer.tc(fn -> Logger.error("slow") end)
    assert us >= 20_000
  end

  test "04-64: a handler that logs from inside log/2 DOES recurse into itself (no OTP guard)" do
    c = :counters.new(1, [])
    add(:recurse, {:recurse, c})
    Logger.error("outer")
    Process.sleep(50)
    n = :counters.get(c, 1)
    events = BeamLab.Capture.collect(100)
    File.write!(@log, "04-64 recursive handler calls=#{n} capture got #{length(events)} events\n", [:append])
    # first run red: no protection at all; only our own cap (1000) stopped it
    assert n == 1000
  end

  test "04-65: 10k Logger.error from 100 processes: a sync handler receives all 10k (no drop in :logger core, no Elixir discard_threshold)" do
    me = self()
    {us, _} = :timer.tc(fn ->
      1..100
      |> Enum.map(fn i -> Task.async(fn -> for j <- 1..100, do: Logger.error("flood #{i}-#{j}") end) end)
      |> Task.await_many(60_000)
    end)
    n = count_events(0)
    File.write!(@log, "04-65 10k Logger.error from 100 procs: #{us} us, capture handler received #{n}\n", [:append])
    assert n == 10_000
    _ = me
  end

  test "04-66: logger_std_h (file, default olp settings) under a 10k flood from 100 processes drops a large share" do
    path = Path.expand("../../../logs/04-flood-std_h.txt", __DIR__)
    File.rm(path)
    :ok = :logger.add_handler(:flood_file, :logger_std_h, %{level: :all, config: %{file: String.to_charlist(path)}})
    {us, _} = :timer.tc(fn ->
      1..100
      |> Enum.map(fn i -> Task.async(fn -> for j <- 1..100, do: Logger.error("flood #{i}-#{j}") end) end)
      |> Task.await_many(60_000)
    end)
    :logger_std_h.filesync(:flood_file)
    Process.sleep(500)
    :logger_std_h.filesync(:flood_file)
    :logger.remove_handler(:flood_file)
    lines = File.read!(path) |> String.split("\n", trim: true)
    written = Enum.count(lines, &(&1 =~ "flood "))
    notices = Enum.filter(lines, &(&1 =~ ~r/drop|flush/i))
    count_events(0)
    File.write!(@log, "04-66 std_h flood: #{us} us, written #{written}/10000, notices #{inspect(notices)}\n", [:append])
    assert written < 5_000
  end

  test "04-67: logger_std_h burst limit: 2000 sequential events from ONE process -> about 500 written per second window" do
    path = Path.expand("../../../logs/04-burst-std_h.txt", __DIR__)
    File.rm(path)
    :ok = :logger.add_handler(:burst_file, :logger_std_h, %{level: :all, config: %{file: String.to_charlist(path)}})
    {us, _} = :timer.tc(fn -> for j <- 1..2000, do: Logger.error("burst #{j}") end)
    Process.sleep(1200)
    :logger_std_h.filesync(:burst_file)
    :logger.remove_handler(:burst_file)
    lines = File.read!(path) |> String.split("\n", trim: true)
    written = Enum.count(lines, &(&1 =~ "burst "))
    notices = Enum.filter(lines, &(&1 =~ ~r/drop|flush|burst/i) and not (&1 =~ "burst "))
    count_events(0)
    File.write!(@log, "04-67 std_h burst: #{us} us, written #{written}/2000, notices #{inspect(notices)}\n", [:append])
    assert written in 490..520
  end

  test "04-68: 10k crashing plain processes -> :logger_proxy enters drop mode and the VM discards most crash reports" do
    {us, _} = :timer.tc(fn -> for _ <- 1..10_000, do: spawn(fn -> raise "flood" end) end)
    events = BeamLab.Capture.collect(1000)
    crashes = Enum.count(events, &match?(%{meta: %{error_logger: %{emulator: true}}}, &1))
    notices = for %{level: l, msg: m} = e <- events, not match?(%{meta: %{error_logger: %{emulator: true}}}, e),
                do: {l, inspect(m, limit: 8) |> String.slice(0, 120)}
    File.write!(@log, "04-68 10k plain crashes: spawn loop #{us} us, crash events received #{crashes}, other events #{inspect(notices)}\n", [:append])
    # first run red (predicted all 10k): 1719 arrived
    assert crashes < 10_000
  end

  test "04-69: with a 1 ms handler, 5k plain crashes pile up in :logger_proxy past its drop_mode_qlen (1000) before drop mode reacts" do
    add(:slow1, {:sleep, 1})
    for _ <- 1..5_000, do: spawn(fn -> raise "flood" end)
    Process.sleep(100)
    {:message_queue_len, q} = Process.info(Process.whereis(:logger_proxy), :message_queue_len)
    n = count_events(0, 3000)
    File.write!(@log, "04-69 5k plain crashes, 1 ms handler: logger_proxy qlen after 100 ms #{q}, capture received #{n}\n", [:append])
    # prediction n < 5000 was red in 1 of 3 runs (5002 = all 5000 + 2 mode notices): drop mode reacts late,
    # the count is timing-dependent (3455..5000). The stable fact: the queue overshoots 1000.
    assert q > 1000
    assert n <= 5_002
  end

  defp count_events(n, wait \\ 300) do
    receive do
      {:log_event, _, _} -> count_events(n + 1, wait)
    after
      wait -> n
    end
  end
end
