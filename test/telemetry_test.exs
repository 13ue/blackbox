defmodule Blackbox.TelemetryTest do
  # The metadata shapes are lab 05's, recorded from Phoenix 1.8 on Bandit.
  use ExUnit.Case, async: false
  require Logger
  alias Blackbox.{Fixtures.Sites, Sink}

  defmodule NotFound do
    defexception message: "not found", plug_status: 404
  end

  setup do
    Sink.attach()
    Sink.collect(50)
    :ok
  end

  defp in_request(fun) do
    {:ok, pid} = Task.start(fn -> fun.() end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 1000
  end

  defp phoenix_500(e, st) do
    wrapper = %Plug.Conn.WrapperError{kind: :error, reason: e, stack: st, conn: nil}

    :telemetry.execute([:phoenix, :router_dispatch, :exception], %{}, %{
      kind: :error,
      reason: wrapper,
      stacktrace: st
    })

    :telemetry.execute([:phoenix, :error_rendered], %{}, %{
      status: 500,
      kind: :error,
      reason: e,
      stacktrace: st
    })

    :telemetry.execute([:bandit, :request, :exception], %{}, %{
      kind: :error,
      exception: e,
      stacktrace: st
    })

    Logger.error("** (RuntimeError) here", crash_reason: {e, st})
  end

  defp grab(fun) do
    fun.()
  rescue
    e -> {e, __STACKTRACE__}
  end

  test "05-5: one Phoenix 500 on Bandit, seen four times in one process, is one occurrence" do
    in_request(fn ->
      {e, st} = grab(&Sites.raise_here/0)
      phoenix_500(e, st)
    end)

    assert [%{type: "RuntimeError", count: 1, samples: [s]}] = Sink.collect()
    assert s.source == [:phoenix, :router_dispatch, :exception]
    assert hd(s.stacktrace).text =~ "Sites.raise_here/0"
  end

  test "two 500s in one keep-alive connection process are two occurrences" do
    in_request(fn ->
      for _ <- 1..2 do
        {e, st} = grab(&Sites.raise_here/0)
        phoenix_500(e, st)
      end
    end)

    assert [%{type: "RuntimeError", count: 2}] = Sink.collect()
  end

  test "05-7: an exception with plug_status below 500 is counted as expected, not an issue" do
    e0 = Blackbox.stats().expected

    in_request(fn ->
      e = %NotFound{}

      :telemetry.execute([:phoenix, :router_dispatch, :exception], %{}, %{
        kind: :error,
        reason: e,
        stacktrace: []
      })

      :telemetry.execute([:phoenix, :error_rendered], %{}, %{
        status: 404,
        kind: :error,
        reason: e,
        stacktrace: []
      })

      :telemetry.execute([:bandit, :request, :exception], %{}, %{
        kind: :error,
        exception: e,
        stacktrace: []
      })
    end)

    assert Sink.collect() == []
    assert Blackbox.stats().expected - e0 == 3
  end

  test "04-79: a raising telemetry handler is one issue, not also telemetry's own log" do
    :telemetry.attach(
      "bb-test-raises",
      [:bb_test, :event],
      fn _, _, _, _ -> raise "handler boom" end,
      nil
    )

    :telemetry.execute([:bb_test, :event], %{}, %{})
    assert [%{type: "RuntimeError", title: "handler boom", count: 1}] = Sink.collect()
  end
end
