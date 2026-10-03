defmodule Lab05.LiveViewTest do
  # Real LiveView over a real WebSocket (dead render via HTTP, then join lv:<id>). Predictions before first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  alias Lab05.WS
  import Lab05.HTTP

  @port 4351

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Lab05.PubSub})
    start_supervised!(Lab05.Endpoint)
    :ok
  end

  setup do
    C.start()
    on_exit(&C.stop/0)
    :ok
  end

  defp html(path) do
    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{@port}#{path}", [{~c"accept", ~c"text/html"}]}, [], [])
    {status, to_string(body)}
  end

  defp live_join do
    {200, body} = html("/lv")
    [_, id] = Regex.run(~r/id="(phx-[^"]+)"/, body)
    [_, session] = Regex.run(~r/data-phx-session="([^"]+)"/, body)
    [_, static] = Regex.run(~r/data-phx-static="([^"]*)"/, body)
    {s, "HTTP/1.1 101" <> _} = WS.connect(@port, "/live/websocket?vsn=2.0.0")
    topic = "lv:" <> id
    WS.push(s, ["4", "4", topic, "phx_join", %{"url" => "http://127.0.0.1:#{@port}/lv", "params" => %{}, "session" => session, "static" => static}])
    {:ok, [_, _, ^topic, "phx_reply", %{"status" => "ok"}]} = WS.recv(s)
    C.collect(100)
    {s, topic}
  end

  test "05-33: raise in mount on the dead render: HTTP 500, live_view mount exception telemetry + router_dispatch + bandit + one log, all one pid" do
    {500, _} = html("/lv?crash=mount")
    msgs = C.collect()
    [m] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :live_view, :mount, :exception]))
    IO.puts("05-33 mount exception meta keys: #{inspect(Map.keys(m.meta))}")
    assert %{kind: :error, reason: %RuntimeError{}, socket: %Phoenix.LiveView.Socket{}} = m.meta
    assert [:phoenix, :router_dispatch, :exception] in C.names(msgs)
    [log] = C.logs(msgs, :error)
    assert log.from == m.from
  end

  test "05-34: handle_event raise over WS: handle_event exception telemetry + one gen_server crash report, both in the LV pid" do
    {s, topic} = live_join()
    WS.push(s, ["4", "5", topic, "event", %{"type" => "click", "event" => "boom", "value" => %{"x" => "1"}}])
    frames = WS.recv_all(s)
    msgs = C.collect()
    IO.puts("05-34 frames: #{inspect(frames) |> String.slice(0, 200)}")
    [t] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :live_view, :handle_event, :exception]))
    IO.puts("05-34 handle_event exception meta keys: #{inspect(Map.keys(t.meta))}")
    assert %{event: "boom", params: %{"x" => "1"}, kind: :error, reason: %RuntimeError{}} = t.meta
    [log] = C.logs(msgs, :error)
    assert log.from == t.from
    assert {:report, %{label: {:gen_server, :terminate}, last_message: last}} = log.msg
    IO.puts("05-34 last_message: #{inspect(last, limit: 6) |> String.slice(0, 250)}")
    IO.puts("05-34 process_label: #{inspect(elem(log.msg, 1)[:process_label])}")
  end

  test "05-35: handle_info raise: one crash report, no LiveView exception telemetry" do
    {s, _topic} = live_join()
    send(:persistent_term.get(:lab05_lv), :boom)
    _ = WS.recv_all(s)
    msgs = C.collect()
    assert [_] = C.logs(msgs, :error)
    assert C.tels(msgs, :exception) == []
  end

  test "05-36: the LV crash report state holds all assigns, incl. a secret" do
    {s, topic} = live_join()
    WS.push(s, ["4", "5", topic, "event", %{"type" => "click", "event" => "boom", "value" => %{}}])
    _ = WS.recv_all(s)
    [log] = C.logs(C.collect(), :error)
    {:report, %{state: state}} = log.msg
    assert inspect(state, limit: :infinity) =~ "hunter2"
  end
end
