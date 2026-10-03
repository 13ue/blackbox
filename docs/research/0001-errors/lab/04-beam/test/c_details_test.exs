defmodule BeamLab.DetailsTest do
  use BeamLab.Case
  alias BeamLab.{Srv, Deep}
  require Logger

  test "04-31: Process.set_label in a plain spawn -> the emulator event carries no label" do
    spawn(fn -> Process.set_label(:plain_x); crash(:raise) end)
    [e] = run("04-31 label plain", fn -> :ok end)
    refute inspect(e, limit: :infinity) =~ "plain_x"
  end

  test "04-32: Process.set_label in a Task -> report.process_label" do
    Task.start(fn -> Process.set_label({:job, 7}); crash(:raise) end)
    [e] = run("04-32 label task", fn -> :ok end)
    assert {:report, %{report: %{process_label: {:job, 7}}}} = e.msg
  end

  test "04-33: Process.set_label in a GenServer -> report.process_label" do
    {:ok, pid} = GenServer.start(Srv, {:label, :srv_x})
    [e] = run("04-33 label genserver", fn -> GenServer.cast(pid, {:do, :raise}) end)
    assert {:report, %{process_label: :srv_x}} = e.msg
  end

  test "04-34: backtrace_depth (8 in a plain VM, 20 under ExUnit) truncates crash stacks; raising it to 64 keeps 21+ frames" do
    # first run red: ExUnit.Runner sets it to its :stacktrace_depth (20); `erl`/`elixir` alone report 8
    exunit = :erlang.system_flag(:backtrace_depth, 8)
    assert exunit == 20
    # first run red (2nd): self-recursion at one call site is collapsed to a single frame
    spawn(fn -> Deep.down(20) end)
    [e] = run("04-34a self recursion", fn -> :ok end)
    {_, stack} = e.meta.crash_reason
    assert [{Deep, :down, 1, _}, {Deep, :down, 1, _}] = stack

    spawn(fn -> Deep.a(20) end)
    [e] = run("04-34a depth 8", fn -> :ok end)
    {_, stack} = e.meta.crash_reason
    assert length(stack) == 8

    old = :erlang.system_flag(:backtrace_depth, 64)
    assert old == 8
    try do
      spawn(fn -> Deep.a(20) end)
      [e] = run("04-34b depth 64", fn -> :ok end)
      {_, stack} = e.meta.crash_reason
      assert length(stack) >= 21
    after
      :erlang.system_flag(:backtrace_depth, exunit)
    end
  end

  test "04-35: GenServer started with debug: [log: 5] -> report.log holds the last :sys events" do
    {:ok, pid} = GenServer.start(Srv, %{}, debug: [log: 5])
    :pong = GenServer.call(pid, :ping)
    :pong = GenServer.call(pid, :ping)
    [e] = run("04-35 sys log", fn -> GenServer.cast(pid, {:do, :raise}) end)
    assert {:report, %{log: log}} = e.msg
    assert length(log) in 1..5
    File.write!("../../logs/04-sys-log.txt", inspect(log, pretty: true))
  end

  test "04-36: Logger.metadata of the dying process: present for Task and GenServer reports, absent for plain spawn" do
    Task.start(fn -> Logger.metadata(request_id: "r1"); crash(:raise) end)
    [t] = run("04-36a md task", fn -> :ok end)
    assert t.meta.request_id == "r1"

    {:ok, pid} = GenServer.start(Srv, %{})
    :sys.replace_state(pid, fn s -> Logger.metadata(request_id: "r2"); s end)
    [g] = run("04-36b md genserver", fn -> GenServer.cast(pid, {:do, :raise}) end)
    assert g.meta.request_id == "r2"

    spawn(fn -> Logger.metadata(request_id: "r3"); crash(:raise) end)
    [p] = run("04-36c md plain", fn -> :ok end)
    refute Map.has_key?(p.meta, :request_id)
  end

  test "04-37: Application.stop -> one :notice {:application_controller, :exit} event, reason :stopped" do
    BeamLab.LabApp.load()
    {:ok, _} = Application.ensure_all_started(:lab_app)
    BeamLab.Capture.collect(50)
    [e] = run("04-37 app stop", fn -> :ok = Application.stop(:lab_app) end)
    # first run red: level is :notice, not :info
    assert e.level == :notice
    assert {:report, %{label: {:application_controller, :exit}, report: r}} = e.msg
    assert r[:exited] == :stopped
  end

  test "04-38: a temporary app whose top supervisor is killed -> only a :notice event" do
    BeamLab.LabApp.load()
    {:ok, _} = Application.ensure_all_started(:lab_app)
    BeamLab.Capture.collect(50)
    sup = Process.whereis(BeamLab.LabApp.Sup)
    [e] = run("04-38 app crash", fn -> Process.exit(sup, :kill) end)
    # first run red: :notice. An app dying is below :warning, so an :error-level tracker misses it
    assert e.level == :notice
    assert {:report, %{report: r}} = e.msg
    assert r[:exited] == :killed
    assert r[:type] == :temporary
  end
end
