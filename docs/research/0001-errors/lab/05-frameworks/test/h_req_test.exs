defmodule Lab05.ReqTest do
  # Req 0.7.4 / Finch 0.23. Predictions written before the first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C

  @up "http://127.0.0.1:4354"

  setup_all do
    start_supervised!({Bandit, plug: Lab05.Upstream, port: 4354, ip: {127, 0, 0, 1}})
    :ok
  end

  setup do
    C.start()
    on_exit(&C.stop/0)
    :ok
  end

  defp finch_stops(msgs), do: C.tels(msgs, :stop) |> Enum.filter(&(&1.name == [:finch, :request, :stop]))

  test "05-54: a 500 with retry: false is {:ok, %Req.Response{status: 500}}: no log, no exception event" do
    assert {:ok, %Req.Response{status: 500}} = Req.get(@up <> "/500", retry: false)
    msgs = C.collect()
    assert C.logs(msgs, :warning) == []
    assert Enum.filter(C.tels(msgs, :exception), &(hd(&1.name) == :finch)) == []
    # first run RED: Req drives Finch.stream, so the result is {:ok, stream accumulator}, not a %Finch.Response{}
    [s] = finch_stops(msgs)
    {:ok, acc} = s.meta.result
    IO.puts("05-54 shape: #{inspect(Tuple.to_list(acc) |> Enum.map(fn x -> if is_struct(x), do: {x.__struct__, Map.get(x, :status)}, else: x end))}")
    # second form RED too: the accumulator is Req's internal {req, {status, headers, body, trailers}}
    assert {:ok, {%Req.Request{}, {500, _headers, _body, _trailers}}} = s.meta.result
  end

  test "05-55: default retry on a GET 500: three :warning logs from the caller pid, four finch requests, final {:ok, 500}" do
    me = self()
    assert {:ok, %Req.Response{status: 500}} = Req.get(@up <> "/500", retry_delay: fn _ -> 10 end)
    msgs = C.collect()
    warns = C.logs(msgs, :warning)
    IO.puts("05-55 warnings: #{inspect(Enum.map(warns, &(C.text(&1) |> String.slice(0, 120))))}")
    assert length(warns) == 3
    assert Enum.all?(warns, &(&1.from == me))
    assert length(finch_stops(msgs)) == 4
  end

  test "05-56: connection refused with retry: false: {:error, %Req.TransportError{reason: :econnrefused}}; finch stop carries the error; no exception event; no log" do
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Req.get("http://127.0.0.1:4399/", retry: false)
    msgs = C.collect()
    [s] = finch_stops(msgs)
    IO.puts("05-56 finch stop meta keys: #{inspect(Map.keys(s.meta))} result=#{inspect(s.meta.result) |> String.slice(0, 120)}")
    # first run RED: a 3-tuple {:error, %Finch.TransportError{}, acc} (stream accumulator), not {:error, _}
    assert {:error, %Finch.TransportError{reason: :econnrefused}, _acc} = s.meta.result
    assert Enum.filter(C.tels(msgs, :exception), &(hd(&1.name) == :finch)) == []
    assert C.logs(msgs, :warning) == []
  end

  test "05-57: receive timeout: {:error, %Req.TransportError{reason: :timeout}} (retry: false)" do
    assert {:error, %Req.TransportError{reason: :timeout}} = Req.get(@up <> "/slow", retry: false, receive_timeout: 50)
  end

  test "05-58: Req.get! on a refused connection raises Req.TransportError in the caller" do
    assert_raise Req.TransportError, fn -> Req.get!("http://127.0.0.1:4399/", retry: false) end
  end
end
