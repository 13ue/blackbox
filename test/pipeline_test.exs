defmodule Blackbox.PipelineTest do
  use ExUnit.Case, async: false
  require Logger
  alias Blackbox.{Buffer, Sink}

  setup do
    Sink.attach()
    Sink.collect(50)
    :ok
  end

  defp count_of(issues, title),
    do: issues |> Enum.filter(&(&1.title == title)) |> Enum.map(& &1.count) |> Enum.sum()

  test "08-14: a writer that raises on every batch: buffer and handler survive, counts are kept" do
    buf = Process.whereis(Buffer)
    Buffer.set_writer(fn _ -> raise "writer down" end)
    for _ <- 1..100, do: Logger.error("kept while writer is broken")
    Buffer.flush()
    Process.sleep(300)
    Buffer.flush()
    Process.sleep(300)
    assert Process.whereis(Buffer) == buf
    assert {:ok, _} = :logger.get_handler_config(:blackbox)
    Sink.attach()
    issues = Sink.collect()
    assert count_of(issues, "kept while writer is broken") == 100
    refute Enum.any?(issues, &(&1.title =~ "writer down"))
  end

  test "08-15: a hung writer is killed after the timeout and its batch is retried" do
    f0 = Blackbox.stats().writer_failures
    Buffer.set_writer(fn _ -> Process.sleep(:infinity) end)
    Logger.error("survives a hung writer")
    Buffer.flush()
    Process.sleep(Buffer.writer_timeout() + 100)
    Sink.attach()
    Process.sleep(Buffer.writer_timeout() + 200)
    assert Blackbox.stats().writer_failures > f0
    assert count_of(Sink.collect(), "survives a hung writer") == 1
  end

  test "08-16: what the writer logs and how it crashes is never captured" do
    Buffer.set_writer(fn _ ->
      Logger.error("inside the writer")
      raise "writer crash"
    end)

    Logger.error("trigger")
    Buffer.flush()
    Process.sleep(300)
    Sink.attach()
    issues = Sink.collect()
    assert count_of(issues, "trigger") == 1
    refute Enum.any?(issues, &(&1.title =~ ~r/inside the writer|writer crash/))
  end

  test "08-17: malformed crash reasons are kept, not raised on" do
    before = Blackbox.stats().handler_errors
    Logger.error("poison", crash_reason: {:not_a_stacktrace, :bad})
    Logger.error("poison", crash_reason: {:x, [:not_a_frame]})
    assert {:ok, _} = :logger.get_handler_config(:blackbox)
    assert Blackbox.stats().handler_errors == before
    assert Sink.collect() |> Enum.map(& &1.count) |> Enum.sum() == 2
  end

  test "08-17b: a handler body that raises is caught and counted, and the handler stays" do
    before = Blackbox.stats().handler_errors

    assert Blackbox.Capture.log(%{level: :error, meta: :not_a_map, msg: {:string, "x"}}, %{}) ==
             :ok

    assert Blackbox.Capture.filter(
             %{msg: {:report, %{label: :x}}, level: :error, meta: :not_a_map},
             nil
           ) == :ignore

    assert Blackbox.stats().handler_errors == before + 2
    assert {:ok, _} = :logger.get_handler_config(:blackbox)
    Logger.error("after poison")
    assert count_of(Sink.collect(), "after poison") == 1
  end

  test "a poison batch is retried without samples after 3 failures, and dropped and counted after 6" do
    me = self()
    d0 = Blackbox.stats().dropped

    Buffer.set_writer(fn batch ->
      send(me, {:attempt, Enum.map(batch, &length(&1.samples))})
      :error
    end)

    Logger.error("poison batch")

    attempts =
      for _ <- 1..6,
          do:
            (
              Buffer.flush()
              assert_receive({:attempt, a}, 1000)
              a
            )

    assert attempts == [[1], [1], [1], [0], [0], [0]]
    Process.sleep(50)
    assert Blackbox.stats().dropped - d0 == 1
    Buffer.flush()
    refute_receive {:attempt, _}, 200
  end

  test "08-31: without a flush, the 100 ms tick writes within 400 ms" do
    Logger.error("tick only")
    assert_receive {:batch, [%{count: 1, title: "tick only"}]}, 400
  end

  test "08-18: the mailbox bound drops and counts instead of growing when the buffer is stuck" do
    :sys.suspend(Buffer)
    before = Blackbox.stats().dropped
    for _ <- 1..(Buffer.max_inflight() + 500), do: Logger.error("stuck buffer")
    {:message_queue_len, q} = Process.info(Process.whereis(Buffer), :message_queue_len)
    :sys.resume(Buffer)
    assert q <= Buffer.max_inflight() + 5
    assert Blackbox.stats().dropped - before == 500
    assert count_of(Sink.collect(), "stuck buffer") == Buffer.max_inflight()
  end

  test "a flood of one fingerprint keeps the first, one in-between and the latest sample" do
    for n <- 1..10, do: Logger.error("sampled", n: n)
    Buffer.flush()
    assert_receive {:batch, [%{count: 10, samples: samples}]}, 1000
    assert length(samples) == 3
    assert [first, _, last] = Enum.map(samples, & &1.at)
    assert first < last
  end

  test "10-1: a real repeat from the same source in one process within 1 s counts" do
    me = self()

    pid =
      spawn(fn ->
        for _ <- 1..2 do
          try do
            raise ArgumentError, "same bug"
          rescue
            e ->
              :telemetry.execute([:plug, :router_dispatch, :exception], %{}, %{
                kind: :error,
                reason: e,
                stacktrace: __STACKTRACE__
              })
          end
        end

        send(me, :done)
        receive do: (:stop -> :ok)
      end)

    assert_receive :done
    issues = Sink.collect()
    send(pid, :stop)
    assert [%{type: "ArgumentError", count: 2}] = issues
  end

  test "10-2: a high-cardinality log flood from one call site is one issue" do
    letters = Enum.to_list(?a..?z)

    for _ <- 1..2_000,
        do:
          Logger.error(
            "board #{for _ <- 1..8, into: "", do: <<Enum.random(letters)>>} failed to save"
          )

    assert [%{type: "log", count: 2_000}] = Sink.collect()
  end
end
