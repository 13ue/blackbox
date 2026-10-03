defmodule Lab05.DedupeTest do
  # Can the logger handler tell that telemetry already reported this failure? Predictions before first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  import Lab05.HTTP

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Lab05.PubSub})
    start_supervised!(Lab05.Endpoint)
    start_supervised!(Lab05.CowboyEndpoint)
    :ok
  end

  setup do
    Lab05.Dedupe.start(self())
    C.start()
    on_exit(fn -> Lab05.Dedupe.stop(); C.stop() end)
    :ok
  end

  test "05-59: Bandit: the logger handler sees the process-dictionary mark left by the telemetry handler (same process, telemetry first)" do
    {500, _} = req(4351, :get, "/raise")
    assert_receive {:dedupe_log, true}, 1000
  end

  test "05-60: Cowboy: the mark is NOT visible to the logger handler (log runs in the connection pid)" do
    {500, _} = req(4352, :get, "/raise")
    assert_receive {:dedupe_log, false}, 1000
  end

  test "05-61: the exception term is == across router_dispatch (unwrapped), bandit and the log, and so are the stacktraces" do
    {500, _} = req(4351, :get, "/raise")
    msgs = C.collect()
    [log] = C.logs(msgs, :error)
    {lex, lst} = log.meta.crash_reason
    [rd] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    [bd] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:bandit, :request, :exception]))
    assert rd.meta.reason.reason == lex
    assert bd.meta.exception == lex
    assert bd.meta.stacktrace == lst
    IO.puts("05-61 router stack == log stack? #{rd.meta.stacktrace == lst}; wrapper.stack == log stack? #{rd.meta.reason.stack == lst}")
    assert rd.meta.reason.stack == lst
  end

  test "05-62: Logger metadata set in the request (request_id) is NOT inherited by a Task's crash log; only $callers links it" do
    {200, _} = req(4351, :get, "/task_md")
    msgs = C.collect()
    [log] = C.logs(msgs, :error)
    refute Map.has_key?(log.meta, :request_id)
    assert [_ | _] = log.meta.callers
  end

  test "05-63: LiveView handle_event: the gen_server crash report runs in the LV pid after the telemetry exception, so the mark is visible" do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, {~c"http://127.0.0.1:4351/lv", [{~c"accept", ~c"text/html"}]}, [], [])
    body = to_string(body)
    [_, id] = Regex.run(~r/id="(phx-[^"]+)"/, body)
    [_, session] = Regex.run(~r/data-phx-session="([^"]+)"/, body)
    [_, static] = Regex.run(~r/data-phx-static="([^"]*)"/, body)
    {s, _} = Lab05.WS.connect(4351, "/live/websocket?vsn=2.0.0")
    topic = "lv:" <> id
    Lab05.WS.push(s, ["4", "4", topic, "phx_join", %{"url" => "http://127.0.0.1:4351/lv", "params" => %{}, "session" => session, "static" => static}])
    {:ok, _} = Lab05.WS.recv(s)
    Lab05.WS.push(s, ["4", "5", topic, "event", %{"type" => "click", "event" => "boom", "value" => %{}}])
    assert_receive {:dedupe_log, true}, 1000
  end
end
