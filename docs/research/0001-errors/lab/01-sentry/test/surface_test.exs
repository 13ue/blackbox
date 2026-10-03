defmodule Lab01.SurfaceTest do
  # Claims written before the first run; expectations are what the source
  # read of sentry-elixir 13.5.1 predicts.
  use Lab01.Case, async: false
  require Logger

  defmodule Srv do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_cast(:boom, _s), do: raise("cast boom")
    def handle_call(:sleep, _f, s), do: (Process.sleep(500); {:reply, :ok, s})
  end

  defp quiet(fun), do: ExUnit.CaptureLog.capture_log(fun)

  test "01-1: with default Sentry config (no :logs) a GenServer crash reaches Sentry: no event" do
    quiet(fn ->
      {:ok, pid} = GenServer.start(Srv, %{secret: 1})
      GenServer.cast(pid, :boom)
      Process.sleep(100)
    end)

    assert captured() == []
  end

  # First run RED: last_message/genserver_state are nil. For an exception
  # crash_reason the handler goes straight to capture_exception and never
  # parses the "Last message"/"State" text (Elixir 1.20.4, OTP 28).
  test "01-2a: handler attached, GenServer cast raise -> one exception event WITHOUT last_message or state" do
    attach()

    quiet(fn ->
      {:ok, pid} = GenServer.start(Srv, %{secret: 1})
      GenServer.cast(pid, :boom)
      Process.sleep(100)
    end)

    assert [e] = captured()
    assert title(e) == "RuntimeError: cast boom"
    refute Map.has_key?(e.extra, :last_message)
    refute Map.has_key?(e.extra, :genserver_state)
    assert e.extra.domain == [:otp]
  end

  test "01-2b: handler attached, Task.start raise -> one exception event" do
    attach()
    quiet(fn -> Task.start(fn -> raise "task boom" end); Process.sleep(100) end)
    assert [e] = captured()
    assert title(e) == "RuntimeError: task boom"
  end

  test "01-2c: handler attached, bare spawn raise -> one exception event" do
    attach()
    quiet(fn -> spawn(fn -> raise "spawn boom" end); Process.sleep(100) end)
    assert [e] = captured()
    assert title(e) == "RuntimeError: spawn boom"
  end

  test "01-2d: handler attached, Task.start exit(:boom) -> one message event" do
    attach()
    quiet(fn -> Task.start(fn -> exit(:boom) end); Process.sleep(100) end)
    assert [e] = captured()
    assert title(e) =~ "boom"
    assert e.exception == []
  end

  test "01-2e: handler attached, Task.start throw -> one event" do
    attach()
    quiet(fn -> Task.start(fn -> throw(:ball) end); Process.sleep(100) end)
    assert [e] = captured()
    assert title(e) =~ "ball"
  end

  test "01-2f: handler attached, Logger.error without a crash -> no event (capture_log_messages false)" do
    attach()
    quiet(fn -> Logger.error("just a log line") end)
    assert captured() == []
  end

  test "01-2g: handler attached, capture_log_messages: true -> Logger.error is an event, Logger.warning is not" do
    attach(%{capture_log_messages: true})
    quiet(fn -> Logger.error("just a log line"); Logger.warning("warn line") end)
    assert [e] = captured()
    assert title(e) == "just a log line"
  end

  test "01-2h: supervised GenServer crash -> exactly one event (supervisor report not a second event)" do
    attach()

    quiet(fn ->
      {:ok, sup} = Supervisor.start_link([%{id: Srv, start: {GenServer, :start_link, [Srv, %{}, [name: :lab_srv]]}}], strategy: :one_for_one)
      GenServer.cast(:lab_srv, :boom)
      Process.sleep(200)
      Supervisor.stop(sup)
    end)

    assert [e] = captured()
    assert title(e) == "RuntimeError: cast boom"
  end

  # First run RED: a bare spawn that exits (not raises) is never logged by
  # the BEAM at all, so no handler can see it. Split into 2i (spawn) and 2k (Task).
  test "01-2i: GenServer.call timeout in a bare spawned caller -> no event (the VM logs nothing)" do
    attach()

    quiet(fn ->
      {:ok, pid} = GenServer.start(Srv, %{})
      spawn(fn -> GenServer.call(pid, :sleep, 50) end)
      Process.sleep(700)
    end)

    assert captured() == []
  end

  test "01-2k: GenServer.call timeout in a Task caller -> message event, fingerprint embeds the call term" do
    attach()

    quiet(fn ->
      {:ok, pid} = GenServer.start(Srv, %{})
      Task.start(fn -> GenServer.call(pid, :sleep, 50) end)
      Process.sleep(700)
    end)

    assert [e] = captured()
    assert ["timeout", "genserver_call", ":sleep"] = e.fingerprint
    assert e.exception == []
  end

  test "01-2j: a rescued-and-swallowed exception -> no event" do
    attach()
    try do
      raise "swallowed"
    rescue
      _ -> :ok
    end

    assert captured() == []
  end
end
