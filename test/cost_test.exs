defmodule Blackbox.CostTest do
  # Budgets in reductions, asserted; wall time is printed, never asserted (R-14).
  use ExUnit.Case, async: false
  alias Blackbox.{Buffer, Capture, Crumbs, Sink}
  alias Blackbox.Fixtures.Gs

  setup do
    Buffer.set_writer(fn _ -> :ok end)
    Sink.collect(50)
    :ok
  end

  # Reductions and µs per call of `fun`, in a fresh process with 20 crumbs.
  defp cost(n, fun) do
    Task.async(fn ->
      for i <- 1..20, do: Crumbs.add(:info, {:string, "crumb #{i}"})
      fun.()
      {:reductions, r0} = Process.info(self(), :reductions)
      {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
      {:reductions, r1} = Process.info(self(), :reductions)
      {div(r1 - r0, n), Float.round(us / n, 2)}
    end)
    |> Task.await(30_000)
  end

  defp crash_event do
    stack =
      for i <- 1..12,
          do: {:"Elixir.MyApp.Mod#{i}", :fun, 2, [file: ~c"lib/my_app/mod.ex", line: i]}

    %{
      level: :error,
      msg: {:string, "crash"},
      meta: %{
        pid: self(),
        time: :os.system_time(:microsecond),
        crash_reason: {%RuntimeError{message: "x"}, stack},
        mfa: {:gen_server, :error_info, 8}
      }
    }
  end

  test "reduction budgets of every path in the calling process" do
    n = 1_000

    {crash_r, crash_us} =
      cost(n, fn ->
        Capture.log(%{crash_event() | meta: %{crash_event().meta | pid: self()}}, %{})
      end)

    Buffer.flush()

    {crumb_r, crumb_us} =
      cost(n, fn ->
        Capture.log(
          %{level: :info, msg: {:string, "a crumb"}, meta: %{pid: self(), time: 1}},
          %{}
        )
      end)

    {pass_r, pass_us} =
      cost(n, fn -> Capture.filter(%{level: :info, msg: {:string, "x"}, meta: %{}}, nil) end)

    report = %{
      label: {:proc_lib, :crash},
      report: [
        [
          initial_call: {Gs, :init, [:x]},
          pid: self(),
          registered_name: [],
          process_label: :undefined,
          error_info:
            {:error, %RuntimeError{message: "x"}, elem(crash_event().meta.crash_reason, 1)},
          ancestors: [],
          message_queue_len: 0,
          links: []
        ],
        []
      ]
    }

    {report_r, report_us} =
      cost(n, fn ->
        Capture.filter(
          %{
            level: :error,
            msg: {:report, report},
            meta: %{pid: self(), time: 1, domain: [:otp, :sasl]}
          },
          nil
        )
      end)

    IO.puts("""
    cost per call (reductions, µs): crash via handler=#{crash_r}, #{crash_us} | log crumb=#{crumb_r}, #{crumb_us} | \
    filter pass-through=#{pass_r}, #{pass_us} | proc_lib report via filter=#{report_r}, #{report_us}\
    """)

    assert crash_r < 3_000
    assert report_r < 3_000
    # 63 raw, 84 with the key pre-check, 123 with one host pattern (~0.7 µs)
    assert crumb_r < 150
    assert pass_r < 10
  end

  test "a crash with a 1 MB state sends a size marker, not the state" do
    Sink.attach()
    big = Map.new(1..30_000, &{&1, "value #{&1}"})
    assert :erts_debug.flat_size(big) * 8 > 1_000_000

    crash = fn ->
      {:ok, g} = Gs.start(big)
      {us, _} = :timer.tc(fn -> catch_exit(GenServer.call(g, :raise)) end)
      us
    end

    Blackbox.pause()
    without = Enum.min(for _ <- 1..3, do: crash.())
    Blackbox.resume()
    with_bb = Enum.min(for _ <- 1..3, do: crash.())
    [%{samples: [s | _]}] = Sink.collect()

    IO.puts(
      "1 MB state, call + crash round trip: #{without} µs without Blackbox, #{with_bb} µs with; state sent as #{s.locals.state}"
    )

    assert s.locals.state =~ "{:too_big,"
  end
end
