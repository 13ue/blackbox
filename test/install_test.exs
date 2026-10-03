defmodule Blackbox.InstallTest do
  use ExUnit.Case, async: false
  require Logger
  alias Blackbox.{Capture, Sink}

  setup do
    Sink.attach()
    Sink.collect(50)
    on_exit(fn -> Blackbox.resume() end)
    :ok
  end

  defp filters, do: Keyword.keys(:logger.get_primary_config().filters)

  test "our filter runs first, before Elixir's translator" do
    assert hd(filters()) == :blackbox_sasl
    assert :blackbox in :logger.get_handler_ids()
  end

  test "10-7: Logger.add_translator keeps our filter ahead of the translator" do
    Logger.add_translator({Blackbox.InstallTest.Noop, :translate})
    ids = filters()
    Logger.remove_translator({Blackbox.InstallTest.Noop, :translate})

    assert Enum.find_index(ids, &(&1 == :blackbox_sasl)) <
             Enum.find_index(ids, &(&1 == :logger_translator))
  end

  test "the watchdog re-adds a removed handler, filter and telemetry, and says capture was off" do
    :logger.remove_handler(:blackbox)
    :logger.remove_primary_filter(:blackbox_sasl)
    :telemetry.detach("blackbox")
    Capture.check()
    assert hd(filters()) == :blackbox_sasl
    assert :blackbox in :logger.get_handler_ids()
    assert Enum.any?(:telemetry.list_handlers([]), &(&1.id == "blackbox"))
    assert [%{type: "log", title: "capture was off" <> _}] = Sink.collect()
  end

  test "the watchdog puts the filter back first when another filter got ahead" do
    :ok = :logger.add_primary_filter(:someone_else, {fn _, _ -> :ignore end, nil})
    on_exit(fn -> :logger.remove_primary_filter(:someone_else) end)
    Capture.check()
    assert hd(filters()) == :blackbox_sasl
  end

  test "pause and resume; the watchdog does not fight a pause" do
    Blackbox.pause()
    Capture.check()
    refute :blackbox in :logger.get_handler_ids()
    Logger.error("while paused")
    assert Sink.collect() == []
    Blackbox.resume()
    Logger.error("after resume")
    assert [%{title: "after resume"}] = Sink.collect()
  end

  test "after 5 re-installs in 10 minutes the watchdog gives up with one event" do
    for _ <- 1..6 do
      :logger.remove_handler(:blackbox)
      Capture.check()
    end

    refute :blackbox in :logger.get_handler_ids()
    titles = Sink.collect() |> Enum.map(& &1.title)
    assert Enum.any?(titles, &(&1 =~ "capture gave up"))
  end

  test "the console prints byte for byte the same with and without Blackbox" do
    run = fn file ->
      :ok =
        :logger.add_handler(:console_cmp, :logger_std_h, %{
          config: %{file: String.to_charlist(file)},
          formatter: Logger.default_formatter(colors: [enabled: false])
        })

      Logger.info("hello", pid: :fixed)
      Logger.error("an error")
      Task.start(fn -> raise "task boom" end)
      :proc_lib.spawn(fn -> raise "proc_lib boom" end)
      Process.sleep(200)
      :logger.remove_handler(:console_cmp)

      File.read!(file)
      |> String.replace(~r/\d\d:\d\d:\d\d\.\d+|#PID<[\d.]+>|#Reference<[\d.]+>/, "*")
    end

    dir = System.tmp_dir!()
    with_bb = run.(Path.join(dir, "bb_on.log"))
    Blackbox.pause()
    without = run.(Path.join(dir, "bb_off.log"))
    Blackbox.resume()
    assert with_bb =~ "task boom"
    assert with_bb == without
  end
end

defmodule Blackbox.InstallTest.Noop do
  def translate(_, _, _, _), do: :none
end
