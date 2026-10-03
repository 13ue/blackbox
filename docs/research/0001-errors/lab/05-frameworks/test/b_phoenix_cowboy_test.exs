defmodule Lab05.PhoenixCowboyTest do
  # Plug.Cowboy for contrast. Predictions written before the first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  import Lab05.HTTP

  @port 4352

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Lab05.PubSub})
    start_supervised!(Lab05.Repo)
    start_supervised!(Lab05.CowboyEndpoint)
    :ok
  end

  setup do
    C.start()
    on_exit(&C.stop/0)
    :ok
  end

  defp hit(path) do
    res = req(@port, :get, path)
    {res, C.collect()}
  end

  test "05-18: Cowboy: a controller raise gives one :error log with crash_reason and conn in metadata" do
    {{500, _}, msgs} = hit("/raise")
    assert [log] = C.logs(msgs, :error)
    assert {%RuntimeError{}, [_ | _]} = log.meta.crash_reason
    assert %Plug.Conn{request_path: "/raise"} = log.meta.conn
    IO.puts("05-18 cowboy log meta keys: #{inspect(Map.keys(log.meta))}")
    IO.puts("05-18 cowboy log text: #{C.text(log) |> String.slice(0, 200)}")
  end

  test "05-19: Cowboy: [:cowboy, :request, :exception] fires once, and the log is emitted from a different pid than router_dispatch" do
    {_, msgs} = hit("/raise")
    [log] = C.logs(msgs, :error)
    [cow] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:cowboy, :request, :exception]))
    [rd] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    IO.puts("05-19 cowboy exception meta keys: #{inspect(Map.keys(cow.meta))}")
    IO.puts("05-19 pids: log=#{inspect(log.from)} cowboy=#{inspect(cow.from)} router=#{inspect(rd.from)}")
    assert log.from == cow.from
    assert log.from != rd.from
  end

  test "05-20: Cowboy: plug_status 404 exception is not logged, but cowboy exception telemetry fires" do
    {{404, _}, msgs} = hit("/not_found")
    assert C.logs(msgs, :error) == []
    assert [:cowboy, :request, :exception] in C.names(msgs)
  end

  test "05-21: Cowboy: Task crash from a request has $callers = [request pid] (same as Bandit)" do
    {{200, _}, msgs} = hit("/task")
    [log] = C.logs(msgs, :error)
    [stop] = C.tels(msgs, :stop) |> Enum.filter(&(&1.name == [:phoenix, :endpoint, :stop]))
    assert stop.from in log.meta.callers
  end

  # first run RED: meta.pid is the connection process (where cowboy_telemetry_h runs), not the request process,
  # and meta.reason is the whole exit reason {{exception, stack}, {Plug.Cowboy.Handler-style call info}}
  test "05-22: Cowboy: the cowboy exception runs in the connection pid (meta.pid = self), not the request pid; reason is the nested exit" do
    {_, msgs} = hit("/raise")
    [cow] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:cowboy, :request, :exception]))
    [rd] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    IO.puts("05-22 reason=#{inspect(cow.meta.reason, limit: 6, printable_limit: 60) |> String.slice(0, 300)}")
    assert cow.meta.pid == cow.from
    assert cow.meta.pid != rd.from
    assert {{%RuntimeError{}, [_ | _]}, _call} = cow.meta.reason
  end
end
