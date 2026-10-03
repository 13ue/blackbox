defmodule BeforeLab.SysScrubTest do
  use ExUnit.Case, async: false
  alias BeforeLab.Capture

  defmodule Scrubbed do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_cast({:set, pw}, s), do: {:noreply, %{s | password: pw}}
    def handle_cast(:crash, _s), do: raise("x")
    def format_status(status), do: Map.update!(status, :state, &%{&1 | password: "[scrubbed]"})
  end

  test "06-35: format_status/1 scrubbing only :state leaves the secret in the :sys debug log entries" do
    Capture.attach(:cap, :error, self())
    on_exit(fn -> :logger.remove_handler(:cap) end)
    {:ok, pid} = GenServer.start(Scrubbed, %{password: nil}, debug: [log: 10])
    GenServer.cast(pid, {:set, "hunter2"})
    GenServer.cast(pid, :crash)
    assert_receive {:logged, %{msg: {:report, %{label: {:gen_server, :terminate}} = r}}, _, _}, 500
    assert r.state == %{password: "[scrubbed]"}
    assert inspect(r.log) =~ "hunter2"
  end
end
