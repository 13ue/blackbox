defmodule Blackbox.FloodTest do
  # `mix test --include flood`. Paced floods; counts in memory (the store is M2).
  use ExUnit.Case, async: false
  @moduletag :flood
  @moduletag timeout: 120_000
  require Logger
  import Blackbox.Load

  setup do
    {writer, read} = counter()
    Blackbox.Buffer.set_writer(writer)
    settle(3)
    {c0, _, _} = read.()
    %{read: fn -> elem(read.(), 0) - c0 end, d0: Blackbox.stats().dropped}
  end

  test "08-27: 10k Logger.error/s for 5 s: no drops, every one counted", %{read: read, d0: d0} do
    sent = paced(10_000, 5, fn p, i -> Logger.error("flood #{p} item #{i}") end)
    settle()
    assert Blackbox.stats().dropped == d0
    assert read.() == sent
  end

  test "08-28: 10k Task crashes/s for 3 s: every crash counted", %{read: read} do
    sent = paced(10_000, 3, fn _, _ -> Task.start(fn -> raise "task flood" end) end)
    settle()
    assert read.() == sent
  end

  test "08-29: 10k plain spawn crashes/s for 3 s: they pass :logger_proxy, so a bound", %{
    read: read
  } do
    sent = paced(10_000, 3, fn _, _ -> spawn(fn -> raise "spawn flood" end) end)
    settle()
    assert read.() >= sent * 0.95
  end

  test "10-2: a high-cardinality flood at 10k/s groups by call site and drops nothing", %{d0: d0} do
    {writer, read} = counter()
    Blackbox.Buffer.set_writer(writer)
    letters = Enum.to_list(?a..?z)

    sent =
      paced(10_000, 2, fn _, _ ->
        Logger.error(
          "board #{for _ <- 1..8, into: "", do: <<Enum.random(letters)>>} failed to save"
        )
      end)

    settle()
    {counted, issues, _} = read.()
    assert counted == sent
    assert issues <= 40
    assert Blackbox.stats().dropped == d0
  end

  test "10-15: a one-fingerprint flood writes at most 3 samples per fingerprint per tick" do
    {writer, read} = counter()
    Blackbox.Buffer.set_writer(writer)
    sent = paced(10_000, 2, fn p, _ -> Logger.error("one fp flood #{p}") end)
    settle(10)
    {counted, issues, samples} = read.()
    assert counted == sent
    assert samples <= 3 * issues
  end
end
