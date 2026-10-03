defmodule Lab05.CostTest do
  # Costs of the dedupe key and of keeping the conn. Predictions before first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  import Lab05.HTTP

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Lab05.PubSub})
    start_supervised!(Lab05.Endpoint)
    :ok
  end

  defp per_op_us(n, f) do
    {t, _} = :timer.tc(fn -> for _ <- 1..n, do: f.() end)
    t / n
  end

  test "05-64: the pdict mark + check is < 1 us; phash2 of exception + stacktrace < 10 us; the full conn is > 10x a picked summary (first run: predicted > 5 KB, was 3.5 KB)" do
    C.start()
    {500, _} = req(4351, :post, "/secret", ~s({"password":"hunter2","name":"x"}))
    msgs = C.collect()
    C.stop()
    [rd] = C.tels(msgs, :exception) |> Enum.filter(&(&1.name == [:phoenix, :router_dispatch, :exception]))
    %{reason: %{reason: ex, stack: st, conn: conn}} = rd.meta

    mark = per_op_us(100_000, fn -> Process.put(:bb_seen, [ex]); ex in Process.get(:bb_seen) end)
    key = per_op_us(100_000, fn -> :erlang.phash2({ex.__struct__, ex, st}) end)
    full = :erlang.external_size(conn)
    summary = %{method: conn.method, path: conn.request_path, route: rd.meta.route, status: 500,
                params: Map.new(conn.params, fn {k, v} -> {k, if(k in ~w(password token secret), do: "[FILTERED]", else: v)} end),
                request_id: nil, remote_ip: conn.remote_ip, user_agent: nil}
    small = :erlang.external_size(summary)
    ins = per_op_us(1_000, fn -> inspect(conn, limit: :infinity) end)
    IO.puts("05-64 #{:erlang.system_info(:otp_release)} mark=#{Float.round(mark, 3)}us phash2(ex,st)=#{Float.round(key, 3)}us frames=#{length(st)} conn_external=#{full}B summary=#{small}B inspect(conn)=#{Float.round(ins, 1)}us")
    assert mark < 1
    assert key < 10
    # first run RED: 3533 B external for this small JSON request, not > 5 KB; still ~19x the summary
    assert full > 10 * small
    assert small < 1_000
  end
end
