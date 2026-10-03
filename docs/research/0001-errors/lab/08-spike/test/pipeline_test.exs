defmodule Spike.PipelineTest do
  use ExUnit.Case, async: false
  require Logger

  setup do
    Spike.Buffer.set_writer(Spike.Sink.to(self()))
    Spike.Sink.collect(50)
    :ok
  end

  defp count_of(issues, msg), do: issues |> Enum.filter(&(hd(&1.samples).message == msg)) |> Enum.map(& &1.count) |> Enum.sum()

  test "08-14: a writer that raises on every batch: buffer and handler survive, nothing loops, counts are kept for later" do
    buf = Process.whereis(Spike.Buffer)
    Spike.Buffer.set_writer(fn _ -> raise "writer down" end)
    for _ <- 1..100, do: Logger.error("kept while writer is broken")
    Spike.Buffer.flush(); Process.sleep(300); Spike.Buffer.flush(); Process.sleep(300)
    assert Process.whereis(Spike.Buffer) == buf
    assert {:ok, _} = :logger.get_handler_config(:spike)
    assert Spike.stats().writer_failures >= 2
    Spike.Buffer.set_writer(Spike.Sink.to(self()))
    issues = Spike.Sink.collect()
    assert count_of(issues, "kept while writer is broken") == 100
    refute Enum.any?(issues, &(hd(&1.samples).message =~ "writer down"))
  end

  test "08-15: a writer that hangs is killed after the timeout and its batch is retried" do
    Spike.Buffer.set_writer(fn _ -> Process.sleep(:infinity) end)
    Logger.error("survives a hung writer")
    Spike.Buffer.flush(); Process.sleep(Spike.Buffer.writer_timeout() + 100)
    Spike.Buffer.set_writer(Spike.Sink.to(self()))
    # red on first run: the retry had gone into a second hung task; wait one more timeout
    Process.sleep(Spike.Buffer.writer_timeout() + 200)
    assert Spike.stats().writer_failures >= 1
    assert count_of(Spike.Sink.collect(), "survives a hung writer") == 1
  end

  test "08-16: what the writer logs and how it crashes is never captured (no recursion)" do
    Spike.Buffer.set_writer(fn _ -> Logger.error("inside the writer"); raise "writer crash" end)
    Logger.error("trigger")
    Spike.Buffer.flush(); Process.sleep(300)
    Spike.Buffer.set_writer(Spike.Sink.to(self()))
    issues = Spike.Sink.collect()
    assert count_of(issues, "trigger") == 1
    refute Enum.any?(issues, &(hd(&1.samples).message =~ ~r/inside the writer|writer crash/))
  end

  test "08-17: a poison event that makes normalization raise does not detach the handler" do
    before = Spike.stats().handler_errors
    Logger.error("poison", crash_reason: {:not_a_stacktrace, :bad})
    assert {:ok, _} = :logger.get_handler_config(:spike)
    assert Spike.stats().handler_errors == before + 1
    Logger.error("after poison")
    assert count_of(Spike.Sink.collect(), "after poison") == 1
  end

  test "08-17b: a report with a label Elixir does not know is dropped by the translator before any handler" do
    :logger.log(:error, %{label: :my_lib_report, detail: 1}, %{})
    assert Spike.Sink.collect() == []
  end

  test "08-31: without any flush call, the 100 ms tick writes a batch within 400 ms" do
    Logger.error("tick only")
    assert_receive {:batch, [%{count: 1, samples: [%{message: "tick only"}]}]}, 400
  end

  test "08-18: the mailbox bound drops (and counts) instead of growing when the buffer is stuck" do
    :sys.suspend(Spike.Buffer)
    before = Spike.stats().dropped
    for _ <- 1..(Spike.Buffer.max_inflight() + 500), do: Logger.error("stuck buffer")
    {:message_queue_len, q} = Process.info(Process.whereis(Spike.Buffer), :message_queue_len)
    :sys.resume(Spike.Buffer)
    assert q <= Spike.Buffer.max_inflight() + 5
    assert Spike.stats().dropped - before == 500
    assert count_of(Spike.Sink.collect(), "stuck buffer") == Spike.Buffer.max_inflight()
  end
end
