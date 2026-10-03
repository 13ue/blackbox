defmodule Lab05.PhoenixBanditTest do
  # Predictions written before the first run. First outcome recorded in the report.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  import Lab05.HTTP

  @port 4351

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Lab05.PubSub})
    start_supervised!(Lab05.Repo)
    start_supervised!(Lab05.Endpoint)
    :ok
  end

  setup do
    C.start()
    on_exit(&C.stop/0)
    :ok
  end

  defp hit(method \\ :get, path, body \\ nil) do
    res = req(@port, method, path, body)
    {res, C.collect()}
  end

  test "05-1: a controller raise gives exactly one :error log with crash_reason {exception, stacktrace}" do
    {{500, _}, msgs} = hit("/raise")
    assert [log] = C.logs(msgs, :error)
    assert {%RuntimeError{message: "boom from controller"}, [_ | _]} = log.meta.crash_reason
  end

  test "05-2: Bandit puts the conn into the log metadata" do
    {{500, _}, msgs} = hit("/raise")
    [log] = C.logs(msgs, :error)
    assert %Plug.Conn{request_path: "/raise"} = log.meta[:conn]
  end

  # first run RED: a controller :error is wrapped by Phoenix.Controller.Pipeline in Plug.Conn.WrapperError
  test "05-3: [:phoenix, :router_dispatch, :exception] fires once; for a controller raise the reason is a Plug.Conn.WrapperError" do
    {_, msgs} = hit("/raise")
    assert [t] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    assert %{kind: :error, reason: %Plug.Conn.WrapperError{kind: :error, reason: %RuntimeError{}, conn: inner},
             stacktrace: [_ | _], route: "/raise", plug: Lab05.Controller, plug_opts: :raise_, conn: %Plug.Conn{} = outer} = t.meta
    # the inner conn has the controller's private data; the outer is the conn before the pipeline
    assert inner.private[:phoenix_action] == :raise_
    assert outer.private[:phoenix_action] == nil
  end

  test "05-4: [:bandit, :request, :exception] fires once with the exception and stacktrace" do
    {_, msgs} = hit("/raise")
    assert [t] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:bandit, :request, :exception]))
    assert %{kind: :exit, exception: %RuntimeError{}, stacktrace: [_ | _]} = Map.take(t.meta, [:kind, :exception, :stacktrace]) |> Map.put_new(:kind, :exit)
    IO.puts("05-4 bandit exception meta keys: #{inspect(Map.keys(t.meta))}")
  end

  test "05-5: log and both telemetry sightings run in one pid (the request process)" do
    {_, msgs} = hit("/raise")
    [log] = C.logs(msgs, :error)
    pids = [log.from | Enum.map(C.tels(msgs, :exception), & &1.from)] |> Enum.uniq()
    assert [_one] = pids
  end

  test "05-6: order is router_dispatch exception, error_rendered, bandit exception, log" do
    {_, msgs} = hit("/raise")
    order =
      for m <- msgs, (match?({:tel, _, _, _, _}, m) and elem(m, 2) in [[:phoenix, :router_dispatch, :exception], [:phoenix, :error_rendered], [:bandit, :request, :exception]]) or
                       (match?({:log, _, %{level: :error}}, m)) do
        case m do
          {:tel, _, n, _, _} -> n
          {:log, _, _} -> :log
        end
      end
    IO.puts("05-6 order: #{inspect(order)}")
    assert order == [[:phoenix, :router_dispatch, :exception], [:phoenix, :error_rendered], [:bandit, :request, :exception], :log]
  end

  test "05-7: plug_status 404 exception: no :error log, but router_dispatch and bandit exception events fire" do
    {{404, _}, msgs} = hit("/not_found")
    assert C.logs(msgs, :error) == []
    names = C.names(msgs)
    assert [:phoenix, :router_dispatch, :exception] in names
    assert [:bandit, :request, :exception] in names
  end

  # first run RED: Phoenix.Endpoint.RenderErrors renders NoRouteError and does NOT reraise it (render_errors.ex:95)
  test "05-8: NoRouteError: no log, no router_dispatch exception, NO bandit exception; only error_rendered 404" do
    {{404, _}, msgs} = hit("/nope")
    assert C.logs(msgs, :error) == []
    names = C.names(msgs)
    refute [:phoenix, :router_dispatch, :exception] in names
    refute [:bandit, :request, :exception] in names
    assert [%{meta: %{status: 404, reason: %Phoenix.Router.NoRouteError{}}}] = C.tels(msgs, :error_rendered)
  end

  test "05-9: throw and exit in a controller are logged at :error with kind-shaped crash_reason" do
    {{500, _}, msgs} = hit("/throw")
    [log] = C.logs(msgs, :error)
    IO.puts("05-9 throw crash_reason: #{inspect(log.meta.crash_reason, limit: 3)}")
    assert {{:nocatch, :oops}, _} = log.meta.crash_reason
    [t] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    assert %{kind: :throw, reason: :oops} = t.meta

    {{500, _}, msgs} = hit("/exit")
    [log] = C.logs(msgs, :error)
    IO.puts("05-9 exit crash_reason: #{inspect(log.meta.crash_reason, limit: 3)}")
    assert {:bye, _} = log.meta.crash_reason
  end

  test "05-10: Task.start crash inside a request: one :error log from another pid whose $callers holds the request pid; no exception telemetry" do
    {{200, _}, msgs} = hit("/task")
    [stop] = C.tels(msgs, :stop) |> Enum.filter(&(&1.name == [:phoenix, :endpoint, :stop]))
    [log] = C.logs(msgs, :error)
    assert log.from != stop.from
    assert stop.from in log.meta.callers
    assert {%RuntimeError{message: "boom in task"}, _} = log.meta.crash_reason
    assert C.tels(msgs, :exception) == []
    IO.puts("05-10 task log meta keys: #{inspect(Map.keys(log.meta))}")
  end

  test "05-11: ActionClauseError is plug_status 400: no log, router_dispatch exception, error_rendered 400" do
    {{400, _}, msgs} = hit("/action/2")
    assert C.logs(msgs, :error) == []
    assert [%{meta: %{reason: %Phoenix.ActionClauseError{}}}] =
             C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    assert [%{meta: %{status: 400}}] = C.tels(msgs, :error_rendered)
  end

  test "05-12: malformed JSON raises in the endpoint before the router: no log, no router_dispatch, bandit exception, error_rendered 400" do
    {{400, _}, msgs} = hit(:post, "/json", "{nope")
    assert C.logs(msgs, :error) == []
    refute [:phoenix, :router_dispatch, :exception] in C.names(msgs)
    assert [:bandit, :request, :exception] in C.names(msgs)
    assert [%{meta: %{status: 400, reason: %Plug.Parsers.ParseError{}}}] = C.tels(msgs, :error_rendered)
  end

  test "05-13: send_resp(500) without raising: no log, no exception event; only stop events with status 500" do
    {{500, _}, msgs} = hit("/500")
    assert C.logs(msgs, :warning) == []
    assert C.tels(msgs, :exception) == []
    assert [%{meta: %{conn: %{status: 500}}}] = C.tels(msgs, :stop) |> Enum.filter(&(&1.name == [:phoenix, :endpoint, :stop]))
  end

  test "05-14: Logger.error in a controller: meta has pid, mfa, user_id, request_id absent, no conn" do
    {{200, _}, msgs} = hit("/logged")
    [log] = C.logs(msgs, :error)
    assert log.meta.user_id == 42
    assert {Lab05.Controller, :logged, 2} = log.meta.mfa
    refute Map.has_key?(log.meta, :conn)
    refute Map.has_key?(log.meta, :request_id)
    IO.puts("05-14 Logger.error meta keys: #{inspect(Map.keys(log.meta))}")
  end

  test "05-15: Repo.query! error in a controller: logged at :error (500) and the query event carries {:error, %Postgrex.Error{}}" do
    {{500, _}, msgs} = hit("/db")
    [log] = C.logs(msgs, :error)
    assert {%Postgrex.Error{}, _} = log.meta.crash_reason
    assert [%{meta: %{result: {:error, %Postgrex.Error{}}, query: "select * from no_such_table"}}] =
             C.tels(msgs, :query) |> Enum.filter(&(&1.name == [:lab05, :repo, :query]))
  end

  test "05-16: the conn in router_dispatch exception metadata holds raw params: password is NOT filtered" do
    {_, msgs} = hit(:post, "/secret", ~s({"password":"hunter2","name":"x"}))
    [t] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    assert t.meta.conn.params["password"] == "hunter2"
  end

  test "05-17: [:phoenix, :error_rendered] fires with status 500, kind, reason, stacktrace for a raise" do
    {_, msgs} = hit("/raise")
    assert [%{meta: %{status: 500, kind: :error, reason: %RuntimeError{}, stacktrace: [_ | _]}}] = C.tels(msgs, :error_rendered)
  end

  test "05-23: Bandit's own log for a raise has domain [:bandit]; a garbage request line is logged at :error with no exception telemetry and no Phoenix event" do
    {_, msgs} = hit("/raise")
    [log] = C.logs(msgs, :error)
    # first run RED: Elixir Logger prefixes :elixir to the domain
    assert log.meta.domain == [:elixir, :bandit]

    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: false])
    :ok = :gen_tcp.send(s, "NOT HTTP AT ALL\r\n\r\n")
    _ = :gen_tcp.recv(s, 0, 1000)
    :gen_tcp.close(s)
    msgs = C.collect()
    IO.puts("05-23 garbage names=#{inspect(C.names(msgs))} logs=#{inspect(Enum.map(C.logs(msgs, :debug), &{&1.level, C.text(&1) |> String.slice(0, 120)}))}")
    assert [%{level: :error}] = C.logs(msgs, :error)
    assert C.tels(msgs, :exception) == []
    refute Enum.any?(C.names(msgs), &(hd(&1) == :phoenix))
  end
end
