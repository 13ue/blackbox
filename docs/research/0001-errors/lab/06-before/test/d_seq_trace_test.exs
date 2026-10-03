defmodule BeforeLab.SeqTraceTest do
  use ExUnit.Case, async: false

  defmodule Srv do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_call(:label, _f, s), do: {:reply, label(), s}
    def handle_call(:crash, _f, _s), do: raise("boom")
    def handle_cast({:report_to, pid}, s), do: (send(pid, {:cast_label, label()}); {:noreply, s})
    def handle_info({:report_to, pid}, s), do: (send(pid, {:info_label, label()}); {:noreply, s})
    defp label, do: :seq_trace.get_token(:label)
  end

  setup do
    :seq_trace.set_token([])
    {:ok, pid} = GenServer.start(Srv, nil)
    %{srv: pid}
  end

  test "06-22: a seq_trace label (any term) travels with GenServer.call into the server", %{srv: srv} do
    :seq_trace.set_token(:label, "req-1")
    assert GenServer.call(srv, :label) == {:label, "req-1"}
  end

  test "06-23: a later message without a token clears it: no leak to the next caller", %{srv: srv} do
    # first run was confounded: the Task inherited the test's label (see 06-25). Here the caller clears its own token.
    :seq_trace.set_token(:label, "req-1")
    GenServer.call(srv, :label)
    other = Task.async(fn -> :seq_trace.set_token([]); GenServer.call(srv, :label) end) |> Task.await()
    assert other == []
    # and a plain untokened message after a labelled one also sees no label
    me = self()
    spawn(fn -> :seq_trace.set_token([]); send(srv, {:report_to, me}) end)
    assert_receive {:info_label, []}
  end

  test "06-24: cast and plain send carry the label too", %{srv: srv} do
    :seq_trace.set_token(:label, "req-2")
    GenServer.cast(srv, {:report_to, self()})
    send(srv, {:report_to, self()})
    assert_receive {:cast_label, {:label, "req-2"}}
    assert_receive {:info_label, {:label, "req-2"}}
  end

  test "06-25: spawned processes (Task and raw spawn) DO inherit the label" do
    # first run (red): expected no inheritance. Truth: the spawn carries the token (OTP 28).
    :seq_trace.set_token(:label, "req-3")
    assert Task.async(fn -> :seq_trace.get_token(:label) end) |> Task.await() == {:label, "req-3"}
    me = self()
    spawn(fn -> send(me, {:raw, :seq_trace.get_token(:label)}) end)
    assert_receive {:raw, {:label, "req-3"}}
    # and the spawn_opt without a label keeps none
    :seq_trace.set_token([])
    assert Task.async(fn -> :seq_trace.get_token(:label) end) |> Task.await() == []
  end

  test "06-26: the crash handler of a GenServer that crashed inside a labelled call can read the label", %{srv: srv} do
    me = self()
    :ok = :logger.add_handler(:seq, __MODULE__.H, %{level: :error, config: %{to: me}})
    on_exit(fn -> :logger.remove_handler(:seq) end)
    :seq_trace.set_token(:label, "req-4")
    catch_exit(GenServer.call(srv, :crash))
    assert_receive {:label_at_crash, {:label, "req-4"}}
  end

  defmodule H do
    def log(_e, %{config: %{to: to}}), do: send(to, {:label_at_crash, :seq_trace.get_token(:label)})
  end

  test "06-27: the label comes back on the reply and stays set in the caller", %{srv: srv} do
    :seq_trace.set_token(:label, "req-5")
    GenServer.call(srv, :label)
    assert :seq_trace.get_token(:label) == {:label, "req-5"}
  end
end
