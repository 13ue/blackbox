defmodule Lab05.ChannelTest do
  # Real WebSocket transport over Bandit. Predictions written before the first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  alias Lab05.WS

  @port 4351
  @path "/socket/websocket?vsn=2.0.0"

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

  defp joined(topic) do
    {s, "HTTP/1.1 101" <> _} = WS.connect(@port, @path)
    WS.push(s, ["1", "1", topic, "phx_join", %{}])
    {:ok, ["1", "1", ^topic, "phx_reply", %{"status" => "ok"}]} = WS.recv(s)
    s
  end

  test "05-26: handle_in raise: one :error gen_server crash report from the channel pid with last_message and state; no exception telemetry; no channel_handled_in" do
    s = joined("room:a")
    C.collect(100)
    WS.push(s, ["1", "2", "room:a", "boom", %{"card" => 1}])
    frames = WS.recv_all(s)
    msgs = C.collect()
    IO.puts("05-26 frames after crash: #{inspect(frames)}")
    [log] = C.logs(msgs, :error)
    IO.puts("05-26 channel crash meta keys: #{inspect(Map.keys(log.meta))}")
    assert {:report, %{label: {:gen_server, :terminate}, last_message: last, state: state}} = log.msg
    IO.puts("05-26 last_message: #{inspect(last, limit: 8) |> String.slice(0, 300)}")
    assert %Phoenix.Socket.Message{event: "boom", payload: %{"card" => 1}} = last
    assert %Phoenix.Socket{topic: "room:a"} = state
    assert {%RuntimeError{message: "boom in handle_in"}, [_ | _]} = log.meta.crash_reason
    assert C.tels(msgs, :exception) == []
    refute [:phoenix, :channel_handled_in] in C.names(msgs)
    assert Enum.any?(frames, &match?([_, _, "room:a", "phx_error", _], &1))
  end

  test "05-27: the socket survives a channel crash: another topic on the same socket still answers" do
    s = joined("room:a")
    WS.push(s, ["2", "2", "room:b", "phx_join", %{}])
    {:ok, [_, _, "room:b", "phx_reply", %{"status" => "ok"}]} = WS.recv(s)
    WS.push(s, ["1", "3", "room:a", "boom", %{}])
    _ = WS.recv_all(s)
    WS.push(s, ["2", "4", "room:b", "ping", %{"x" => 1}])
    assert {:ok, [_, "4", "room:b", "phx_reply", %{"status" => "ok", "response" => %{"x" => 1}}]} = WS.recv(s)
  end

  # first run RED: TWO :error logs: the gen_server crash report (channel pid) and a string log from
  # Phoenix.Channel.Server.join/4 in the transport pid
  test "05-28: join raise: two :error logs (crash report + transport-side string), error reply, NO channel_joined" do
    {s, _} = WS.connect(@port, @path)
    C.collect(100)
    WS.push(s, ["1", "1", "room:crash", "phx_join", %{}])
    frames = WS.recv_all(s)
    msgs = C.collect()
    IO.puts("05-28 frames: #{inspect(frames)}")
    assert [crash, str] = C.logs(msgs, :error)
    assert {:report, %{label: {:gen_server, :terminate}, process_label: label}} = crash.msg
    IO.puts("05-28 process_label=#{inspect(label)} string log from transport: #{C.text(str) |> String.slice(0, 160)} mfa=#{inspect(str.meta[:mfa])}")
    assert str.meta.mfa == {Phoenix.Channel.Server, :join, 4}
    # RED on its first evaluation: channel_joined is emitted inside the channel process after join/3
    # returns (channel/server.ex:318); a crashing join never emits it
    assert C.tels(msgs, :channel_joined) == []
  end

  test "05-29: {:reply, {:error, _}} is silent: no log, channel_handled_in fires" do
    s = joined("room:a")
    C.collect(100)
    WS.push(s, ["1", "2", "room:a", "error_reply", %{}])
    {:ok, [_, _, _, "phx_reply", %{"status" => "error"}]} = WS.recv(s)
    msgs = C.collect()
    assert C.logs(msgs, :warning) == []
    assert [:phoenix, :channel_handled_in] in C.names(msgs)
  end

  test "05-30: raise in UserSocket.connect: HTTP 500 on the upgrade, bandit exception and an :error log, no router_dispatch" do
    {_s, status} = WS.connect(@port, @path <> "&fail=raise")
    msgs = C.collect()
    IO.puts("05-30 status line: #{status}; names=#{inspect(C.names(msgs))}")
    assert status =~ "500"
    assert [_] = C.logs(msgs, :error)
    assert [:bandit, :request, :exception] in C.names(msgs)
    refute [:phoenix, :router_dispatch, :exception] in C.names(msgs)
  end

  test "05-31: connect returning :error: 403, nothing logged at warning or above" do
    {_s, status} = WS.connect(@port, @path <> "&fail=deny")
    msgs = C.collect()
    assert status =~ "403"
    assert C.logs(msgs, :warning) == []
  end

  test "05-32: the channel crash log has no $callers link to the transport; the link is state.transport_pid == socket_connected pid" do
    s = joined("room:a")
    msgs0 = C.collect(100)
    [conn] = C.tels(msgs0, :socket_connected)
    WS.push(s, ["1", "2", "room:a", "boom", %{}])
    _ = WS.recv_all(s)
    [log] = C.logs(C.collect(), :error)
    {:report, %{state: state}} = log.msg
    refute Map.has_key?(log.meta, :callers)
    assert state.transport_pid == conn.from
  end
end
