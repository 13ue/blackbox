defmodule Review.DepthTest do
  @moduledoc "Agent 10: what backtrace_depth 32 (ADR 2.1) costs every raise in the host, measured before assuming."
  use ExUnit.Case, async: false

  defp deep(0), do: raise(ArgumentError, "x")
  defp deep(n), do: 1 + deep(n - 1)

  defp per_raise(depth, n) do
    :erlang.system_flag(:backtrace_depth, depth)
    {us, _} = :timer.tc(fn -> for _ <- 1..n, do: (try do deep(40) rescue _ -> :ok end) end)
    us / n
  end

  test "10-16: raising and rescuing 40 frames deep costs < 0.5 µs more per raise at depth 32 than at 8" do
    old = :erlang.system_flag(:backtrace_depth, 8)
    per_raise(8, 20_000)
    d8 = Enum.min(for _ <- 1..5, do: per_raise(8, 100_000))
    d32 = Enum.min(for _ <- 1..5, do: per_raise(32, 100_000))
    :erlang.system_flag(:backtrace_depth, old)
    Spike.Load.log("10-16 raise+rescue 40 deep, µs per raise: depth 8=#{Float.round(d8, 3)} depth 32=#{Float.round(d32, 3)}")
    assert d32 - d8 < 0.5
  end
end
