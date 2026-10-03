defmodule Blackbox.ApiTest do
  # The explicit API: what no hook sees.
  use ExUnit.Case, async: false
  alias Blackbox.Sink

  setup do
    Sink.attach()
    Sink.collect(50)
    :ok
  end

  defp in_task(fun) do
    {:ok, pid} = Task.start(fun)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 1000
  end

  test "capture_exception at a rescue, with context; returns the ref it was stored under" do
    ref =
      try do
        raise ArgumentError, "swallowed"
      rescue
        e -> Blackbox.capture_exception(e, __STACKTRACE__, context: %{board: "b1"})
      end

    assert [%{type: "ArgumentError", count: 1, samples: [s]}] = Sink.collect()
    assert s.ref == ref
    assert s.source == "manual"
    assert s.context == %{"board" => ~s("b1")}
    assert Blackbox.current_ref() == ref
  end

  test "capture_exception then a reraise that crashes the process is one failure" do
    in_task(fn ->
      try do
        raise "rescued then reraised"
      rescue
        e ->
          Blackbox.capture_exception(e, __STACKTRACE__)
          reraise e, __STACKTRACE__
      end
    end)

    assert [%{count: 1}] = Sink.collect()
  end

  test "capture_message groups by its call site, not its text" do
    for id <- ["abc", "xyz"], do: Blackbox.capture_message("sync of #{id} gave up")
    Blackbox.capture_message("other site")
    assert Enum.sort(Enum.map(Sink.collect(), & &1.count)) == [1, 2]
  end

  test "current_ref names the last failure in this process; a crash in a request sets it for the error page" do
    assert Blackbox.current_ref() == nil
    me = self()

    in_task(fn ->
      try do
        raise "in the request"
      rescue
        e ->
          :telemetry.execute([:phoenix, :router_dispatch, :exception], %{}, %{
            kind: :error,
            reason: e,
            stacktrace: __STACKTRACE__
          })

          send(me, {:ref, Blackbox.current_ref()})
      end
    end)

    assert_receive {:ref, ref}
    assert ref =~ ~r/^[0-9a-f]{6}-[a-z2-7]{5}$/
    assert [%{fingerprint: fp, samples: [%{ref: ^ref}]}] = Sink.collect()
    assert String.starts_with?(fp, binary_part(ref, 0, 6))
  end

  test "capture_browser keeps only the known fields, caps them, scrubs the URL and groups by name and stack" do
    stack = fn line ->
      "TypeError: x is undefined\n    at render (https://h/assets/board-3f9a1c.js:#{line}:17)\n    at tick (https://h/assets/board-3f9a1c.js:88:3)"
    end

    for line <- [120, 121] do
      Blackbox.capture_browser(%{
        "name" => "TypeError",
        "message" => "x is undefined",
        "stack" => stack.(line),
        "url" => "https://h/b/private-board?key=ck_live_x",
        "key" => "never-stored",
        "extra" => 1
      })
    end

    Blackbox.capture_browser(%{"message" => String.duplicate("m", 5_000)})

    issues = Sink.collect()

    assert [%{type: "browser TypeError", count: 2, samples: [s | _]}] =
             Enum.filter(issues, &(&1.type == "browser TypeError"))

    assert s.url == "https://h/b/[Filtered]?key=[Filtered]"
    assert s.source == "browser"
    refute inspect(issues) =~ "never-stored"
    assert [%{samples: [long]}] = Enum.filter(issues, &(&1.type == "browser Error"))
    assert byte_size(long.message) < 1_200
  end
end
