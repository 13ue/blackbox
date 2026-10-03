defmodule Lab01.PipelineTest do
  use Lab01.Case, async: false

  test "01-6: identical capture_message twice -> both reach before_send, only the first is sent" do
    Sentry.capture_message("dup 6")
    Sentry.capture_message("dup 6")
    assert length(captured()) == 2
    assert length(sent()) == 1
  end

  test "01-7: dedupe is a sliding window: a repeat refreshes the entry, so a steady error is never sent again" do
    Sentry.capture_message("dup 7")
    Process.sleep(150)
    Sentry.capture_message("dup 7")
    # sweep with ttl 100 ms: the entry was refreshed <100 ms ago, so it survives
    send(Sentry.Dedupe, {:sweep, 100})
    Process.sleep(50)
    Sentry.capture_message("dup 7")
    assert length(sent()) == 1
    # an entry not seen for > ttl is swept, the next one is sent again
    Process.sleep(150)
    send(Sentry.Dedupe, {:sweep, 100})
    Process.sleep(50)
    Sentry.capture_message("dup 7")
    assert length(sent()) == 1
  end

  test "01-8a: Sentry context set in a parent reaches a crashing Task's event via $callers" do
    attach()
    Sentry.Context.set_tags_context(%{req: "abc"})
    ExUnit.CaptureLog.capture_log(fn -> Task.start(fn -> raise "child boom" end); Process.sleep(100) end)
    assert [e] = captured()
    assert e.tags[:req] == "abc"
  end

  test "01-8b: but a manual Sentry.capture_message inside that Task does not get the parent's context" do
    Sentry.Context.set_tags_context(%{req: "abc"})
    {:ok, _} = Task.start(fn -> Sentry.capture_message("from task") end)
    assert [e] = captured()
    refute Map.has_key?(e.tags, :req)
  end

  test "01-8c: breadcrumb timestamps are whole seconds" do
    Sentry.Context.add_breadcrumb(message: "a")
    Sentry.Context.add_breadcrumb(message: "b")
    Sentry.capture_message("with crumbs 8c")
    assert [e] = captured()
    assert [%{timestamp: t1}, %{timestamp: t2}] = e.breadcrumbs
    assert is_integer(t1) and t2 - t1 in [0, 1]
  end
end
