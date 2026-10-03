defmodule BeforeLab.JoinTest do
  use ExUnit.Case, async: false
  require Logger
  alias BeforeLab.Ring

  # a "backend" style handler: forwards the event to a separate process that does the work (like gen_event backends)
  defmodule Backend do
    def start(to), do: spawn(fn -> loop(to) end)
    defp loop(to) do
      receive do
        {:event, e} -> send(to, {:backend_saw, Ring.Pdict.read(), e.meta[:crumbs]}); loop(to)
      end
    end
    def log(e, %{config: %{backend: b}}), do: send(b, {:event, e})
  end

  # the inline handler: joins the crash to its request trail from inside the crashed process
  defmodule Joiner do
    def log(%{level: :error} = e, %{config: %{to: to}}) do
      own = Ring.Pdict.read()
      callers = Process.get(:"$callers", [])
      client =
        case e.msg do
          {:report, %{client_info: {pid, _}}} when is_pid(pid) -> pid
          _ -> nil
        end
      from_callers = Enum.flat_map(callers, &Ring.Pdict.read/1)
      from_client = if client, do: Ring.Pdict.read(client), else: []
      send(to, {:joined, self(), own, from_callers, from_client, :seq_trace.get_token(:label)})
    end
    def log(_, _), do: :ok
  end

  defmodule LongLived do
    use GenServer
    def init(s), do: {:ok, s}
    def handle_call(:crash, _f, _s), do: raise("server boom")
    def handle_cast(:crash, _s), do: raise("cast boom")
  end

  setup do
    Ring.Pdict.clear()
    :seq_trace.set_token([])
    on_exit(fn -> for id <- [:backend, :joiner], do: :logger.remove_handler(id) end)
    :ok
  end

  test "06-49: a backend-style handler (work done in another process) sees no pdict ring, but crumbs carried in event metadata survive" do
    b = Backend.start(self())
    :ok = :logger.add_handler(:backend, Backend, %{level: :all, config: %{backend: b}})
    Ring.Pdict.add(:in_pdict)
    Logger.error("boom", crumbs: [:in_metadata])
    assert_receive {:backend_saw, [], [:in_metadata]}
  end

  test "06-50: Task.Supervisor.async_nolink crash: $callers joins it to the request's ring" do
    start_supervised!({Task.Supervisor, name: JoinSup})
    :ok = :logger.add_handler(:joiner, Joiner, %{level: :error, config: %{to: self()}})
    Ring.Pdict.add(:request_step_1)
    t = Task.Supervisor.async_nolink(JoinSup, fn -> Ring.Pdict.add(:task_step); raise "task boom" end)
    tpid = t.pid
    assert_receive {:joined, ^tpid, [:task_step], [:request_step_1], [], _}, 1000
    Task.yield(t)
  end

  test "06-51: GenServer.call into a long-lived server: $callers is useless, client_info finds the blocked caller's ring" do
    {:ok, srv} = GenServer.start(LongLived, nil)
    :ok = :logger.add_handler(:joiner, Joiner, %{level: :error, config: %{to: self()}})
    Ring.Pdict.add(:request_step_1)
    catch_exit(GenServer.call(srv, :crash))
    # the first :error event is the gen_server terminate report; it runs in the server, while the caller still waits
    assert_receive {:joined, ^srv, [], [], [:request_step_1], []}, 1000
  end

  test "06-52: GenServer.cast into a long-lived server: no client_info, no $callers; only a seq_trace label joins it" do
    {:ok, srv} = GenServer.start(LongLived, nil)
    :ok = :logger.add_handler(:joiner, Joiner, %{level: :error, config: %{to: self()}})
    :seq_trace.set_token(:label, "req-9")
    GenServer.cast(srv, :crash)
    assert_receive {:joined, ^srv, [], [], [], {:label, "req-9"}}, 1000
  end

  test "06-53: fire-and-forget start_child whose request already finished: $callers points at a dead pid, trail lost" do
    start_supervised!({Task.Supervisor, name: JoinSup2})
    :ok = :logger.add_handler(:joiner, Joiner, %{level: :error, config: %{to: self()}})
    me = self()
    req = spawn(fn ->
      Ring.Pdict.add(:request_step_1)
      {:ok, _} = Task.Supervisor.start_child(JoinSup2, fn -> receive do: (:go -> raise "late boom") end)
      |> tap(fn {:ok, t} -> send(me, {:task, t}) end)
    end)
    assert_receive {:task, t}
    ref = Process.monitor(req)
    assert_receive {:DOWN, ^ref, _, _, _}
    send(t, :go)
    assert_receive {:joined, ^t, [], [], [], _}, 1000
  end
end
