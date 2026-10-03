defmodule Spike.Buffer do
  @moduledoc """
  Aggregates samples by fingerprint (count exact, at most #{3} samples each) and hands
  batches to one writer task at a time. Bounded twice: an atomics counter caps messages
  in flight (the handler drops and counts beyond it), and pending holds at most
  @max_fingerprints issues. A failed batch merges back into pending (counts survive).
  """
  use GenServer

  @max_inflight 10_000
  @max_fingerprints 1_000
  @samples 3
  @interval 100
  @writer_timeout 500
  @backoff_max 5_000

  def max_inflight, do: @max_inflight
  def writer_timeout, do: @writer_timeout

  def start_link(writer), do: GenServer.start_link(__MODULE__, writer, name: __MODULE__)

  # Called in the failing process: never blocks, never grows the mailbox past the bound.
  def push(item) do
    if Spike.bump(:inflight) > @max_inflight do
      Spike.bump(:inflight, -1)
      Spike.bump(:dropped)
    else
      send(__MODULE__, {:item, item})
    end
  end

  def flush, do: GenServer.call(__MODULE__, :flush)
  def set_writer(fun), do: GenServer.call(__MODULE__, {:writer, fun})

  @impl true
  def init(writer) do
    Logger.metadata(spike: true)
    :timer.send_interval(@interval, :tick)
    {:ok, %{pending: %{}, writer: writer, task: nil, backoff: 0, retry_at: nil}}
  end

  @impl true
  def handle_info({:item, {fp, type, sample}}, s) do
    Spike.bump(:inflight, -1)
    {:noreply, %{s | pending: add(s.pending, fp, type, sample)}}
  end

  def handle_info(:tick, s), do: {:noreply, maybe_write(s, false)}

  def handle_info({ref, result}, %{task: {%Task{ref: ref}, batch, timer}} = s) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)
    if result == :ok, do: {:noreply, %{s | task: nil, backoff: 0, retry_at: nil}}, else: {:noreply, failed(s, batch)}
  end

  def handle_info({:DOWN, ref, _, _, _}, %{task: {%Task{ref: ref}, batch, timer}} = s) do
    Process.cancel_timer(timer)
    {:noreply, failed(s, batch)}
  end

  def handle_info({:writer_timeout, ref}, %{task: {%Task{ref: ref} = t, _, _}} = s) do
    Process.exit(t.pid, :kill)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def handle_call(:flush, _, s), do: {:reply, :ok, maybe_write(s, true)}
  def handle_call({:writer, fun}, _, s), do: {:reply, :ok, %{s | writer: fun, backoff: 0, retry_at: nil}}

  defp add(pending, fp, type, sample) do
    case pending do
      %{^fp => i} ->
        samples = if length(i.samples) < @samples, do: i.samples ++ [Spike.Event.finish(sample)], else: i.samples
        %{pending | fp => %{i | count: i.count + 1, last_at: sample.at, samples: samples}}

      _ when map_size(pending) >= @max_fingerprints ->
        Spike.bump(:dropped)
        pending

      _ ->
        Map.put(pending, fp, %{fingerprint: fp, type: type, count: 1, first_at: sample.at, last_at: sample.at, samples: [Spike.Event.finish(sample)]})
    end
  end

  defp merge(pending, batch) do
    Enum.reduce(batch, pending, fn i, acc ->
      Map.update(acc, i.fingerprint, i, fn n ->
        %{n | count: n.count + i.count, first_at: i.first_at, samples: Enum.take(i.samples ++ n.samples, @samples)}
      end)
    end)
  end

  defp maybe_write(%{task: nil, pending: p} = s, force) when map_size(p) > 0 do
    # retry_at is nil when there is no backoff: monotonic time is negative on the BEAM, never compare it to 0
    if force or s.retry_at == nil or System.monotonic_time(:millisecond) >= s.retry_at do
      batch = Map.values(p)
      writer = s.writer
      task = Task.Supervisor.async_nolink(Spike.TaskSup, fn -> Logger.metadata(spike: true); writer.(batch) end)
      timer = Process.send_after(self(), {:writer_timeout, task.ref}, @writer_timeout)
      %{s | pending: %{}, task: {task, batch, timer}}
    else
      s
    end
  end

  defp maybe_write(s, _), do: s

  defp failed(s, batch) do
    Spike.bump(:writer_failures)
    backoff = min(max(s.backoff * 2, 50), @backoff_max)
    %{s | task: nil, pending: merge(s.pending, batch), backoff: backoff,
          retry_at: System.monotonic_time(:millisecond) + backoff}
  end
end
