defmodule Lab05.PlugTest do
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  import Lab05.HTTP

  setup_all do
    start_supervised!({Bandit, plug: Lab05.PlainRouter, port: 4353, ip: {127, 0, 0, 1}})
    :ok
  end

  setup do
    :persistent_term.put(:lab05_test_pid, self())
    C.start()
    on_exit(&C.stop/0)
    :ok
  end

  test "05-24: bare Plug.Router emits [:plug, :router_dispatch, :exception] with route and conn" do
    {500, _} = req(4353, :get, "/raise/7")
    msgs = C.collect()
    assert [t] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:plug, :router_dispatch, :exception]))
    IO.puts("05-24 plug router exc meta keys: #{inspect(Map.keys(t.meta))}")
    assert %{route: "/raise/:id", conn: %Plug.Conn{}} = t.meta
  end

  test "05-25: Plug.ErrorHandler.handle_errors runs in the request pid, then the error is reraised and Bandit logs it once" do
    {500, body} = req(4353, :get, "/raise/8")
    msgs = C.collect()
    assert body == "handled"
    assert_received {:handle_errors, hpid, :error, %RuntimeError{}}
    [log] = C.logs(msgs, :error)
    assert log.from == hpid
  end
end
