defmodule Lab05.ObanTest do
  # Oban 2.24 with a real queue (Postgres notifier). Predictions written before the first run.
  use ExUnit.Case, async: false
  alias Lab05.Capture, as: C
  alias Lab05.Workers, as: W

  setup_all do
    start_supervised!(Lab05.Repo)
    Lab05.Repo.query!("delete from oban_jobs")
    start_supervised!({Oban, repo: Lab05.Repo, queues: [default: 5], plugins: [], stage_interval: 100})
    :ok
  end

  setup do
    C.start()
    on_exit(&C.stop/0)
    :ok
  end

  defp run(worker, args \\ %{}) do
    {:ok, job} = Oban.insert(worker.new(args))
    msgs = wait(job.id, System.monotonic_time(:millisecond) + 5000, [])
    {job, msgs ++ C.collect_for(200)}
  end

  defp wait(id, deadline, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)
    receive do
      {:tel, _, [:oban, :job, e], _, %{job: %{id: ^id}}} = m when e in [:stop, :exception] -> Enum.reverse([m | acc])
      m -> wait(id, deadline, [m | acc])
    after
      left -> flunk("job #{id} did not finish")
    end
  end

  defp job_event(msgs, e), do: C.tels(msgs, e) |> Enum.filter(&match?([:oban, :job, _], &1.name))

  test "05-45: a raising job: [:oban, :job, :exception] with kind, reason, stacktrace, job, state :failure; NO :error log" do
    {_, msgs} = run(W.Raise, %{"secret" => "hunter2"})
    [t] = job_event(msgs, :exception)
    IO.puts("05-45 oban exception meta keys: #{inspect(Map.keys(t.meta) |> Enum.sort())}")
    assert %{kind: :error, reason: %RuntimeError{}, stacktrace: [_ | _], state: :failure, job: %Oban.Job{args: %{"secret" => "hunter2"}}} = t.meta
    assert C.logs(msgs, :warning) == []
  end

  test "05-46: last attempt: state :discard" do
    {_, msgs} = run(W.Last)
    assert [%{meta: %{state: :discard}}] = job_event(msgs, :exception)
  end

  test "05-47: {:error, reason}: exception event with reason %Oban.PerformError{}" do
    {_, msgs} = run(W.ErrorTuple)
    assert [%{meta: %{kind: :error, reason: %Oban.PerformError{}}}] = job_event(msgs, :exception)
  end

  test "05-48: {:cancel, _}: a :stop event with state :cancelled, no exception event" do
    {_, msgs} = run(W.Cancel)
    IO.puts("05-48 cancel events: #{inspect(for t <- C.tels(msgs, :stop) ++ C.tels(msgs, :exception), match?([:oban, :job, _], t.name), do: {t.name, t.meta[:state]})}")
    assert [%{meta: %{state: :cancelled}}] = job_event(msgs, :stop)
    assert job_event(msgs, :exception) == []
  end

  test "05-49: {:snooze, 60}: a :stop event with state :snoozed" do
    {_, msgs} = run(W.Snooze)
    assert [%{meta: %{state: :snoozed}}] = job_event(msgs, :stop)
  end

  test "05-50: timeout/1 exceeded: exception event with %Oban.TimeoutError{}" do
    {_, msgs} = run(W.Slow)
    assert [%{meta: %{reason: %Oban.TimeoutError{}}}] = job_event(msgs, :exception)
  end

  # first run RED: a killed job process gives kind :exit, reason :killed (raw), not a CrashError
  test "05-51: the job process killed: exception event kind :exit reason :killed; no :error log" do
    {_, msgs} = run(W.Kill)
    [t] = job_event(msgs, :exception)
    IO.puts("05-51 kill: kind=#{inspect(t.meta.kind)} reason=#{inspect(t.meta.reason) |> String.slice(0, 160)} logs=#{length(C.logs(msgs, :warning))}")
    assert %{kind: :exit, reason: :killed} = t.meta
    assert C.logs(msgs, :warning) == []
  end

  # first run RED: exit/1 inside perform is caught and normalized to kind :error, %Oban.CrashError{reason: :bye}
  test "05-52: exit(:bye) in a job: exception event kind :error with %Oban.CrashError{reason: :bye}, no log" do
    {_, msgs} = run(W.Exit)
    assert [%{meta: %{kind: :error, reason: %Oban.CrashError{reason: :bye}, error: %Oban.CrashError{}}}] = job_event(msgs, :exception)
    assert C.logs(msgs, :warning) == []
  end

  test "05-53: the exception event runs in the job's own process, and a Task spawned by the job logs with $callers = [job pid]" do
    {_, msgs} = run(W.Raise, %{"secret" => "x"})
    [t] = job_event(msgs, :exception)
    [start] = job_event(msgs, :start)
    assert t.from == start.from
    {_, msgs} = run(W.Spawns)
    [start] = job_event(msgs, :start)
    [log] = C.logs(msgs, :error)
    assert start.from in log.meta.callers
  end
end
