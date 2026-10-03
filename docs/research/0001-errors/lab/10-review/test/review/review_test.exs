defmodule Review.Test do
  @moduledoc "Agent 10: claims written BEFORE the first run, with the assertion I believe. First outcomes in 10-review.md."
  use ExUnit.Case, async: false
  require Logger
  alias Spike.Event

  defp counting_writer(ref), do: fn batch ->
    for i <- batch, do: :atomics.add(ref, 1, i.count)
    :atomics.add(ref, 2, length(batch))
    :atomics.add(ref, 3, Enum.sum(for i <- batch, do: length(i.samples)))
    :ok
  end

  setup do
    Spike.Buffer.set_writer(Spike.Sink.to(self()))
    Spike.Sink.collect(50)
    :seq_trace.set_token([])
    :ok
  end

  test "10-1: the pdict dedupe drops (and does not count) a real 2nd failure with the same fingerprint in one long-lived process" do
    parent = self()
    pid = spawn(fn ->
      for n <- 1..2 do
        try do
          raise ArgumentError, "same bug"
        rescue
          e -> :telemetry.execute([:app, :req, :exception], %{}, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        end
        if n == 1, do: Process.sleep(10)
      end
      send(parent, :done)
      receive do: (:stop -> :ok)
    end)
    assert_receive :done
    c0 = Spike.stats().captured
    issues = Spike.Sink.collect()
    send(pid, :stop)
    counts = for i <- issues, i.type == "ArgumentError", do: i.count
    IO.puts("10-1 counts=#{inspect(counts)} captured_delta_after=#{Spike.stats().captured - c0}")
    # belief: two real failures, but the tracker reports ONE and counts one
    assert Enum.sum(counts) == 1
  end

  test "10-2: a high-cardinality Logger.error flood (a letters-only id per message) splits into one issue per message and overruns the buffer" do
    ref = :atomics.new(3, [])
    Spike.Buffer.set_writer(counting_writer(ref))
    d0 = Spike.stats().dropped
    letters = ?a..?z |> Enum.to_list()
    tok = fn -> for(_ <- 1..8, into: "", do: <<Enum.random(letters)>>) end
    {us, sent} = :timer.tc(fn -> Spike.Load.paced(10_000, 2, fn _, _ -> Logger.error("board #{tok.()} failed to save") end) end)
    Enum.each(1..40, fn _ -> Spike.Buffer.flush(); Process.sleep(100) end)
    dropped = Spike.stats().dropped - d0
    counted = :atomics.get(ref, 1)
    issues = :atomics.get(ref, 2)
    samples = :atomics.get(ref, 3)
    Spike.Load.log("10-2 sent=#{sent} in #{div(us, 1000)} ms counted=#{counted} dropped=#{dropped} issues_written=#{issues} samples_written=#{samples}")
    assert issues > 1000
    # flaky as first written: dropped was 74 in one run, 0 in others; drops are timing, the split is not
  end

  test "10-3: two different app call sites that fail inside Ecto/DBConnection share one fingerprint (top-3 non-stdlib frames are all deps)" do
    [{a, _}] = Code.compile_string("defmodule SiteA do\n def run, do: Spike.Repo.query!(\"select 1/0\")\nend", "site_a.ex")
    [{b, _}] = Code.compile_string("defmodule SiteB do\n def other(x), do: x && Spike.Repo.query!(\"select 1/0\")\nend", "site_b.ex")
    grab = fn f -> try do f.() rescue e -> {e, __STACKTRACE__} end end
    {e1, st1} = grab.(fn -> a.run() end)
    {e2, st2} = grab.(fn -> b.other(1) end)
    IO.puts("10-3 top frames A: " <> inspect(Enum.take(st1, 4) |> Enum.map(&elem(&1, 0))))
    assert Event.fingerprint(:error, e1, st1) == Event.fingerprint(:error, e2, st2)
  end

  test "10-5: a raising primary filter is removed; the event still reaches handlers; later events flow" do
    :ok = :logger.add_primary_filter(:review_bad, {fn _, _ -> raise "filter boom" end, nil})
    Logger.error("through a bad filter")
    refute Keyword.has_key?(:logger.get_primary_config().filters, :review_bad)
    issues = Spike.Sink.collect()
    assert Enum.any?(issues, &(hd(&1.samples).message == "through a bad filter"))
  end

  test "10-7: Logger.add_translator (Plug.Cowboy does it at boot) keeps a prepended filter ahead of the translator" do
    :ok = :logger.add_primary_filter(:review_first, {fn _, _ -> :ignore end, nil})
    Logger.add_translator({Review.NoopTranslator, :translate})
    ids = Keyword.keys(:logger.get_primary_config().filters)
    Logger.remove_translator({Review.NoopTranslator, :translate})
    :logger.remove_primary_filter(:review_first)
    IO.puts("10-7 filters after add_translator: #{inspect(ids)}")
    assert Enum.find_index(ids, &(&1 == :review_first)) < Enum.find_index(ids, &(&1 == :logger_translator))
  end

  test "10-8: a domain-match primary filter costs < 0.3 µs per log event that passes the primary level" do
    :ok = :logger.remove_handler(:spike)
    per = fn n -> {us, _} = :timer.tc(fn -> for i <- 1..n, do: Logger.debug("x #{i}") end); us / n end
    per.(20_000)
    without = Enum.min(for _ <- 1..3, do: per.(100_000))
    :ok = :logger.add_primary_filter(:review_cost, {&Review.DomainFilter.filter/2, nil})
    with_f = Enum.min(for _ <- 1..3, do: per.(100_000))
    :logger.remove_primary_filter(:review_cost)
    :ok = :logger.add_handler(:spike, Spike.Handler, %{level: :all})
    Spike.Load.log("10-8 Logger.debug µs/event without filter=#{Float.round(without, 3)} with domain filter=#{Float.round(with_f, 3)}")
    assert with_f - without < 0.3
  end

  test "10-9a: a seq_trace label on the failing process reaches the lib's writer Task when the flush is a labelled call" do
    me = self()
    Spike.Buffer.set_writer(fn _ -> send(me, {:writer_label, :seq_trace.get_token(:label)}); :ok end)
    :seq_trace.set_token(:label, 4242)
    Logger.error("labelled failure")
    Spike.Buffer.flush()
    :seq_trace.set_token([])
    assert_receive {:writer_label, {:label, 4242}}, 1000
  end

  test "10-9b: through the timer tick only (no labelled call), the writer Task has no label" do
    me = self()
    Spike.Buffer.set_writer(fn _ -> send(me, {:writer_label, :seq_trace.get_token(:label)}); :ok end)
    :seq_trace.set_token(:label, 4343)
    Logger.error("labelled failure, tick")
    :seq_trace.set_token([])
    assert_receive {:writer_label, []}, 1000
  end

  test "10-10: a crumb holding a 100-byte slice keeps a 4 MB binary alive in the process after the code dropped it" do
    me = self()
    spawn(fn ->
      big = :crypto.strong_rand_bytes(4_000_000)
      Logger.info(binary_part(big, 0, 100))
      big = nil
      _ = big
      :erlang.garbage_collect()
      {:binary, bins} = Process.info(self(), :binary)
      send(me, {:bins, Enum.map(bins, fn {_, size, _} -> size end)})
    end)
    assert_receive {:bins, sizes}, 1000
    IO.puts("10-10 binaries referenced after GC: #{inspect(sizes)}")
    assert 4_000_000 in sizes
  end

  test "10-11: exception messages embed secret values that a key-name scrubber over params/state never sees" do
    Spike.Repo.query!("CREATE TABLE IF NOT EXISTS review_spaces (name text UNIQUE)")
    Spike.Repo.query!("DELETE FROM review_spaces")
    Spike.Repo.query!("INSERT INTO review_spaces VALUES ('my-private-space')")
    msg = try do
      Spike.Repo.query!("INSERT INTO review_spaces VALUES ($1)", ["my-private-space"])
    rescue
      e -> Exception.message(e)
    end
    key_msg = try do Map.fetch!(%{token: "ck_live_SECRET"}, :missing) rescue e -> Exception.message(e) end
    IO.puts("10-11 postgrex: #{inspect(msg)}\n10-11 keyerror: #{inspect(key_msg)}")
    assert msg =~ "my-private-space"
    assert key_msg =~ "ck_live_SECRET"
  end

  test "10-12: a :logger handler at level :notice never receives :info events (no info crumbs through it)" do
    me = self()
    :ok = :logger.add_handler(:review_notice, Review.Fwd, %{level: :notice, config: %{to: me}})
    Logger.info("an info crumb")
    Logger.warning("a warning")
    :logger.remove_handler(:review_notice)
    assert_receive {:fwd, :warning}, 200
    refute_receive {:fwd, :info}, 100
  end

  test "10-15: a one-fingerprint flood writes up to 3 occurrence rows per 100 ms tick, not one row per 100 ms" do
    Spike.Buffer.set_writer(Spike.Store.writer(Spike.Repo))
    Spike.Buffer.flush(); Process.sleep(300)
    Spike.Repo.query!("TRUNCATE occurrences, issues RESTART IDENTITY")
    sent = Spike.Load.paced(10_000, 2, fn p, _ -> Logger.error("one fp flood #{p}") end)
    Enum.each(1..10, fn _ -> Spike.Buffer.flush(); Process.sleep(100) end)
    [[occ, iss, total]] = Spike.Repo.query!("select (select count(*) from occurrences), (select count(*) from issues), (select coalesce(sum(count),0)::bigint from issues)").rows
    Spike.Load.log("10-15 sent=#{sent} issues=#{iss} occurrences=#{occ} sum(count)=#{total}")
    assert iss == 1
    assert occ > 20
  end
end

defmodule Review.NoopTranslator do
  def translate(_, _, _, _), do: :none
end

defmodule Review.DomainFilter do
  def filter(%{meta: %{domain: [:otp, :sasl | _]}} = e, _), do: (send(self(), {:seen, e}); :ignore)
  def filter(_, _), do: :ignore
end

defmodule Review.Fwd do
  def log(%{level: l}, %{config: %{to: to}}), do: send(to, {:fwd, l})
end
