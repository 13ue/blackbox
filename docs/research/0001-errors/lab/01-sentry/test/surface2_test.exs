defmodule Lab01.Surface2Test do
  use Lab01.Case, async: false

  defmodule BadInit do
    use GenServer
    def init(_), do: raise("init boom")
  end

  defmodule Machine do
    @behaviour :gen_statem
    def callback_mode, do: :handle_event_function
    def init(_), do: {:ok, :idle, %{}}
    def handle_event(:cast, :boom, _s, _d), do: raise("statem boom")
  end

  defp quiet(fun), do: ExUnit.CaptureLog.capture_log(fun)

  # First run RED: on OTP 28 an init/1 crash under GenServer.start emits NO
  # log event at all; the error only exists as the {:error, {exc, stack}}
  # return value of GenServer.start. (sentry issue #542, 2023, still true.)
  test "01-2l: GenServer init/1 raise (GenServer.start) -> no event, only the return value" do
    attach()
    quiet(fn ->
      assert {:error, {%RuntimeError{message: "init boom"}, _}} = GenServer.start(BadInit, nil)
      Process.sleep(100)
    end)
    assert captured() == []
  end

  # Claim written before run: the supervisor's start_error report matches the
  # handler's %{label: {_, _}, report: list} clause, finds no :error_info,
  # crashes inside the rescue and is dropped.
  test "01-2o: supervised child whose init/1 raises -> no event" do
    attach()
    quiet(fn ->
      Process.flag(:trap_exit, true)
      {:error, _} = Supervisor.start_link([%{id: :bad, start: {GenServer, :start_link, [BadInit, nil]}}], strategy: :one_for_one)
      Process.sleep(100)
    end)
    assert captured() == []
  end

  test "01-2m: gen_statem callback raise -> one exception event" do
    attach()

    quiet(fn ->
      {:ok, pid} = :gen_statem.start(Machine, nil, [])
      :gen_statem.cast(pid, :boom)
      Process.sleep(100)
    end)

    assert [e] = captured()
    assert title(e) == "RuntimeError: statem boom"
  end

  # First run RED: only ONE event. The caller is killed by the link's exit
  # signal, which the VM does not log; only the inner Task's crash is logged.
  test "01-2n: Task.async raise awaited by a Task.start caller -> one event (the inner task)" do
    attach()

    quiet(fn ->
      Task.start(fn -> Task.async(fn -> raise "inner boom" end) |> Task.await() end)
      Process.sleep(200)
    end)

    assert [e] = captured()
    assert title(e) == "RuntimeError: inner boom"
  end

  # Why 01-2o is silent (probe: a raw :logger handler got no event at all):
  # Elixir's primary filter stops every SASL/supervisor report before any
  # handler runs, unless config :logger, handle_sasl_reports: true.
  # Elixir 1.20.4 lib/logger/lib/logger/utils.ex:12-13.
  test "01-2p: Elixir's primary logger_translator filter has sasl: false by default" do
    assert {_fun, %{sasl: false}} = :logger.get_primary_config().filters[:logger_translator]
  end
end
