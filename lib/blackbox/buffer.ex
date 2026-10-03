defmodule Blackbox.Buffer do
  @moduledoc false
  # Aggregates samples by fingerprint: an exact count, and the first, one
  # in-between and the latest sample. Hands batches to one writer task at a
  # time. Bounded twice: an :atomics in-flight counter caps its mailbox (the
  # failing process drops and counts past it), and at most @max_fingerprints
  # issues wait. A failed batch is retried; after 3 failures without its
  # samples (one may be the poison), after 6 it is dropped and counted.
  use GenServer
  alias Blackbox.Event

  @max_inflight 10_000
  @max_fingerprints 1_000
  @interval 100
  @writer_timeout 500
  @backoff_max 5_000
  @strip_after 3
  @drop_after 6
  @reported_ms 5_000

  def max_inflight, do: @max_inflight
  def writer_timeout, do: @writer_timeout

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # In the failing process: never blocks, never grows the mailbox past the bound.
  def push(item) do
    if Blackbox.bump(:inflight) > @max_inflight do
      Blackbox.bump(:inflight, -1)
      Blackbox.bump(:dropped)
    else
      send(__MODULE__, {:item, item})
    end
  end

  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "The function that writes a batch; nil holds everything in the buffer."
  def set_writer(fun), do: GenServer.call(__MODULE__, {:writer, fun})

  @doc "Writes everything now, waiting up to `ms`; what fails stays for the spool."
  def drain(ms) do
    GenServer.call(__MODULE__, {:drain, ms}, ms + 1_000)
  catch
    :exit, _ -> :error
  end

  @doc "Takes in what a previous run left in the spool directory."
  def import_spool, do: GenServer.call(__MODULE__, :import_spool)

  @impl true
  def init(_) do
    Logger.metadata(blackbox: true)
    # terminate/2 runs on shutdown, and spools what is left.
    Process.flag(:trap_exit, true)
    :timer.send_interval(@interval, :tick)

    {:ok,
     %{pending: %{}, retry: %{}, writer: nil, task: nil, backoff: 0, retry_at: nil, fails: 0}}
  end

  @impl true
  def handle_info({:item, {fp, sample}}, s) do
    Blackbox.bump(:inflight, -1)
    {:noreply, %{s | pending: add(s.pending, fp, sample)}}
  end

  def handle_info(:tick, s) do
    cutoff = System.monotonic_time(:millisecond) - @reported_ms
    :ets.select_delete(Blackbox.Reported, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    {:noreply, maybe_write(s, false)}
  end

  def handle_info({ref, result}, %{task: {%Task{ref: ref}, batch, timer}} = s) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)

    if result == :ok,
      do: {:noreply, %{s | task: nil, backoff: 0, retry_at: nil, fails: 0}},
      else: {:noreply, failed(s, batch)}
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

  def handle_call({:writer, fun}, _, s),
    do: {:reply, :ok, %{s | writer: fun, backoff: 0, retry_at: nil}}

  def handle_call({:drain, ms}, _, s) do
    s = await(s, ms)

    case {all(s), s.writer} do
      {[], _} ->
        {:reply, :ok, s}

      {_, nil} ->
        {:reply, :error, s}

      {batch, writer} ->
        task =
          Task.Supervisor.async_nolink(Blackbox.TaskSup, fn ->
            Logger.metadata(blackbox: true)
            writer.(batch)
          end)

        s = %{s | pending: %{}, retry: %{}}

        case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, :ok} -> {:reply, :ok, s}
          _ -> {:reply, :error, %{s | retry: merge(%{}, batch)}}
        end
    end
  end

  def handle_call(:import_spool, _, s) do
    retry =
      for path <- spool_files(), reduce: s.retry do
        acc ->
          items =
            try do
              path |> File.read!() |> :erlang.binary_to_term()
            rescue
              _ -> []
            end

          File.rm(path)
          merge(acc, items)
      end

    {:reply, :ok, %{s | retry: retry}}
  end

  @impl true
  def terminate(_, s) do
    with dir when is_binary(dir) <- Application.get_env(:blackbox, :spool_dir),
         [_ | _] = items <- all(kill_task(s)) do
      File.mkdir_p!(dir)

      name =
        "blackbox-#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}.spool"

      File.write!(Path.join(dir, name), :erlang.term_to_binary(items))
    end
  end

  defp spool_files do
    case Application.get_env(:blackbox, :spool_dir) do
      nil -> []
      dir -> Path.wildcard(Path.join(dir, "blackbox-*.spool"))
    end
  end

  # Everything waiting, as writer items: retried batches and new samples.
  defp all(s), do: Map.values(merge(s.retry, for({fp, i} <- s.pending, do: prepare(fp, i))))

  defp await(%{task: {task, batch, timer}} = s, ms) do
    Process.cancel_timer(timer)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> %{s | task: nil}
      _ -> %{s | task: nil, retry: merge(s.retry, batch)}
    end
  end

  defp await(s, _), do: s

  # ponytail: a batch the writer committed just before the kill is spooled too and counted twice; a write id would stop that.
  defp kill_task(%{task: {task, batch, _}} = s) do
    Task.shutdown(task, :brutal_kill)
    %{s | task: nil, retry: merge(s.retry, batch)}
  end

  defp kill_task(s), do: s

  defp add(pending, fp, sample) do
    case pending do
      %{^fp => i} ->
        # The latest moves to the middle, the new one becomes the latest.
        %{
          pending
          | fp => %{
              i
              | count: i.count + 1,
                last_at: sample.at,
                mid: i.last || i.mid,
                last: sample
            }
        }

      _ when map_size(pending) >= @max_fingerprints ->
        Blackbox.bump(:dropped)
        pending

      _ ->
        Map.put(pending, fp, %{
          count: 1,
          first_at: sample.at,
          last_at: sample.at,
          first: sample,
          mid: nil,
          last: nil
        })
    end
  end

  defp maybe_write(%{task: nil, writer: w} = s, force)
       when w != nil and (s.pending != %{} or s.retry != %{}) do
    # retry_at is nil without backoff: monotonic time is negative on the BEAM (08-31)
    if force or s.retry_at == nil or System.monotonic_time(:millisecond) >= s.retry_at do
      batch = merge(s.retry, for({fp, i} <- s.pending, do: prepare(fp, i)))
      batch = Map.values(batch)
      batch = if s.fails >= @strip_after, do: Enum.map(batch, &%{&1 | samples: []}), else: batch
      writer = s.writer

      task =
        Task.Supervisor.async_nolink(Blackbox.TaskSup, fn ->
          Logger.metadata(blackbox: true)
          writer.(batch)
        end)

      timer = Process.send_after(self(), {:writer_timeout, task.ref}, @writer_timeout)
      %{s | pending: %{}, retry: %{}, task: {task, batch, timer}}
    else
      s
    end
  end

  defp maybe_write(s, _), do: s

  # Formatting happens here, only for the samples kept.
  defp prepare(fp, i) do
    samples =
      for(x <- [i.first, i.mid, i.last], x != nil, do: finish(x)) |> Enum.reject(&is_nil/1)

    first = List.first(samples)

    %{
      fingerprint: fp,
      type: (first && first.type) || "unknown",
      title: String.slice((first && first.message) || "", 0, 200),
      count: i.count,
      first_at: i.first_at,
      last_at: i.last_at,
      samples: samples
    }
  end

  defp finish(sample) do
    Event.finish(sample)
  rescue
    _ ->
      Blackbox.bump(:handler_errors)
      nil
  end

  defp merge(acc, items) do
    Enum.reduce(items, acc, fn i, acc ->
      Map.update(acc, i.fingerprint, i, fn o ->
        %{
          o
          | count: o.count + i.count,
            first_at: min(o.first_at, i.first_at),
            last_at: max(o.last_at, i.last_at),
            samples: Enum.take(o.samples ++ i.samples, 3)
        }
      end)
    end)
  end

  defp failed(s, batch) do
    Blackbox.bump(:writer_failures)
    fails = s.fails + 1
    backoff = min(max(s.backoff * 2, 50), @backoff_max)

    s = %{
      s
      | task: nil,
        backoff: backoff,
        retry_at: System.monotonic_time(:millisecond) + backoff,
        fails: fails
    }

    if fails >= @drop_after do
      Blackbox.bump(:dropped, Enum.sum(for i <- batch, do: i.count))
      %{s | fails: 0}
    else
      %{s | retry: merge(s.retry, batch)}
    end
  end
end
