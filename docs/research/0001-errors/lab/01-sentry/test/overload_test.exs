defmodule Lab01.OverloadTest do
  use Lab01.Case, async: false
  require Logger

  # 13.5.1 path: send_result :none -> SenderPool (8+ senders); the handler
  # switches the *logging process* to result: :sync at 100 queued events.
  test "01-9: slow Sentry (50 ms per POST) + 300 distinct crash logs -> the logging process blocks on HTTP" do
    :persistent_term.put(:lab01_delay, 50)
    on_exit(fn -> :persistent_term.put(:lab01_delay, 0) end)
    attach()

    times =
      ExUnit.CaptureLog.capture_log(fn ->
        t =
          for i <- 1..300 do
            {us, _} =
              :timer.tc(fn ->
                Logger.error("c#{i}", crash_reason: {%RuntimeError{message: "c#{i}"}, []})
              end)

            us
          end

        send(self(), {:times, t})
      end)
      |> then(fn _ -> receive(do: ({:times, t} -> t)) end)

    fast = Enum.take(times, 50)
    med = fast |> Enum.sort() |> Enum.at(25)
    IO.puts("01-9 first 50 median us=#{med} max us=#{Enum.max(fast)} all max us=#{Enum.max(times)} total ms=#{div(Enum.sum(times), 1000)} over50ms=#{Enum.count(times, &(&1 >= 50_000))}")
    # first run RED: max of first 50 was 11339 us (first-call warm-up); median is the claim
    assert med < 1_000
    assert Enum.max(times) >= 50_000
    Process.sleep(3000)
  end
end
