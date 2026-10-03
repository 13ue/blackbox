defmodule BeforeLab.PlugTest do
  use ExUnit.Case, async: false
  alias BeforeLab.{Capture, Capture2, LabPlug}
  @port 4361

  setup_all do
    start_supervised!(BeforeLab.Echo)
    start_supervised!({Bandit, plug: LabPlug, port: @port, ip: :loopback, startup_log: false})
    :ok
  end

  setup do
    on_exit(fn -> Capture2.off(); :logger.remove_handler(:cap) end)
    :ok
  end

  defp whoami(req), do: Req.get!(req, url: "/whoami").body |> :erlang.binary_to_term()
  defp client, do: Req.new(base_url: "http://127.0.0.1:#{@port}", retry: false)

  test "06-42: Bandit serves keep-alive requests of one connection in ONE process: pdict and label leak without a reset" do
    req = client()
    {p1, _, _} = whoami(req)
    # plant state as if request 1 had left crumbs and a label
    Req.get!(req, url: "/")
    {p2, _, _} = whoami(req)
    assert p1 == p2
  end

  test "06-43: with the reset on [:bandit, :request, :start], each request starts with an empty ring and a new label" do
    Capture2.on()
    req = client()
    Req.get!(req, url: "/")
    {_p, crumbs, {:label, l1}} = whoami(req)
    {_p, _, {:label, l2}} = whoami(req)
    # the whoami request itself logs nothing, so its ring holds no crumbs from the previous "/" request
    assert crumbs == []
    assert l1 != l2
  end

  test "06-44: a crash in the plug is logged in the request process with that request's crumbs only" do
    Capture2.on()
    Capture.attach(:cap, :error, self())
    req = client()
    Req.get!(req, url: "/")
    Req.get(req, url: "/crash")
    assert_receive {:logged, %{level: :error}, _pid, crumbs}, 1000
    msgs = for {_, :debug, m} <- crumbs, do: IO.iodata_to_binary(m)
    assert msgs == ["about to crash"]
    assert Enum.any?(crumbs, &match?({_, :debug, _}, &1))
    refute Enum.any?(crumbs, &match?({_, [:lab, :repo, :query], _}, &1))
  end

  @tag :bench
  test "06-45: p50/p99 of a Plug request over HTTP and in-process, with vs without full capture" do
    out = for mode <- List.flatten(List.duplicate([:off, :on], 3)) do
      if mode == :on, do: Capture2.on(), else: Capture2.off()
      {mode, http_latencies(8, 2_000), inproc_latencies(20_000)}
    end
    lines = for {mode, http, inproc} <- out do
      "#{mode}: HTTP 8 clients x 2000 p50 #{pct(http, 50)} µs p99 #{pct(http, 99)} µs | in-process Plug p50 #{pct(inproc, 50)} µs p99 #{pct(inproc, 99)} µs"
    end
    File.write!("../../logs/06-plug-latency.log", Enum.join(lines, "\n") <> "\n", [:append])
    IO.puts(Enum.join(lines, "\n"))
  end

  @tag :bench
  test "06-46: which part of the capture costs what (in-process Plug, 3 rounds)" do
    modes = [
      off: [],
      debug_level_only: [:logger],
      debug_level_and_crumb_handler: [:logger, :handler],
      telemetry_crumbs_and_label: [:telemetry],
      all: [:logger, :handler, :telemetry]
    ]
    lines =
      for round <- 1..3, {name, parts} <- modes do
        Capture2.off()
        Capture2.on(parts)
        l = inproc_latencies(20_000)
        "round #{round} #{name}: in-process Plug p50 #{pct(l, 50)} µs p90 #{pct(l, 90)} µs p99 #{pct(l, 99)} µs"
      end
    File.write!("../../logs/06-plug-latency.log", "--- 06-46 decomposition ---\n" <> Enum.join(lines, "\n") <> "\n", [:append])
    IO.puts(Enum.join(lines, "\n"))
  end

  defp pct(list, p), do: Enum.at(Enum.sort(list), div(length(list) * p, 100)) |> Float.round(1)

  defp http_latencies(clients, n) do
    1..clients
    |> Task.async_stream(fn _ ->
      req = client()
      for _ <- 1..200, do: Req.get!(req, url: "/")
      for _ <- 1..n do
        t = System.monotonic_time()
        Req.get!(req, url: "/")
        System.convert_time_unit(System.monotonic_time() - t, :native, :nanosecond) / 1000
      end
    end, timeout: :infinity)
    |> Enum.flat_map(fn {:ok, l} -> l end)
  end

  # the plug called directly; the [:bandit, :request, :start] reset is simulated so the ring cost is the same
  # first version ran in the test process: Plug.Test sends every response to the owner's mailbox, which grew to
  # 40k messages and slowed every later run. Now: a fresh process per run, mailbox flushed per request.
  defp inproc_latencies(n) do
    Task.async(fn ->
      for _ <- 1..2000, do: one_inproc()
      for _ <- 1..n do
        {t, _} = :timer.tc(&one_inproc/0, :nanosecond)
        t / 1000
      end
    end)
    |> Task.await(:infinity)
  end

  defp one_inproc do
    :telemetry.execute([:bandit, :request, :start], %{}, %{})
    conn = Plug.Test.conn(:get, "/")
    LabPlug.call(conn, [])
    :telemetry.execute([:bandit, :request, :stop], %{duration: 1}, %{})
    receive do
      {_ref, {200, _, _}} -> :ok
    after
      0 -> :ok
    end
    receive do
      {:plug_conn, :sent} -> :ok
    after
      0 -> :ok
    end
  end
end
