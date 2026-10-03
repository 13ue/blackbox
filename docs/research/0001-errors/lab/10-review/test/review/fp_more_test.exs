defmodule Review.FpMoreTest do
  @moduledoc "Agent 10: follow-ups to 10-3 (its collision came from tail calls, not from dep frames)."
  use ExUnit.Case, async: false
  alias Spike.Event

  defp grab(f), do: (try do f.() rescue e -> {e, __STACKTRACE__} end)

  test "10-3b: the same Ecto failure from two NON-tail call sites gets two fingerprints (the app frame is within the top 3)" do
    [{a, _}] = Code.compile_string("defmodule SiteC do\n def run, do: {:ok, Spike.Repo.query!(\"select 1/0\")}\nend", "site_c.ex")
    [{b, _}] = Code.compile_string("defmodule SiteD do\n def other(x), do: {x, Spike.Repo.query!(\"select 1/0\")}\nend", "site_d.ex")
    {e1, st1} = grab(fn -> a.run() end)
    {e2, st2} = grab(fn -> b.other(1) end)
    IO.puts("10-3b top frames C: " <> inspect(Enum.take(st1, 4) |> Enum.map(&{elem(&1, 0), elem(&1, 1)})))
    refute Event.fingerprint(:error, e1, st1) == Event.fingerprint(:error, e2, st2)
  end

  test "10-3c: a Jason encode error from two NON-tail call sites shares one fingerprint (>= 3 Jason frames on top)" do
    [{a, _}] = Code.compile_string("defmodule SiteE do\n def run(p), do: {:ok, Jason.encode!(%{a: p})}\nend", "site_e.ex")
    [{b, _}] = Code.compile_string("defmodule SiteF do\n def other(p), do: {:x, Jason.encode!([p])}\nend", "site_f.ex")
    {e1, st1} = grab(fn -> a.run(self()) end)
    {e2, st2} = grab(fn -> b.other(self()) end)
    IO.puts("10-3c top frames E: " <> inspect(Enum.take(st1, 5) |> Enum.map(&{elem(&1, 0), elem(&1, 1)})))
    # red on first run: Jason re-raises from Jason.encode!, one dep frame; the app frame decides
    refute Event.fingerprint(:error, e1, st1) == Event.fingerprint(:error, e2, st2)
  end

  test "10-3d: tail calls erase the app frame: a tail-call site and a different tail-call site in another module collide" do
    [{a, _}] = Code.compile_string("defmodule SiteG do\n def run, do: Map.fetch!(%{}, :k)\nend", "site_g.ex")
    [{b, _}] = Code.compile_string("defmodule SiteH do\n def go, do: Map.fetch!(%{}, :k)\nend", "site_h.ex")
    {e1, st1} = grab(fn -> a.run() end)
    {e2, st2} = grab(fn -> b.go() end)
    IO.puts("10-3d stacks: #{inspect(Enum.map(st1, &elem(&1, 0)))} vs #{inspect(Enum.map(st2, &elem(&1, 0)))}")
    # red on first run: the BIF error keeps SiteG/SiteH; only a tail call into a raising remote fn erases the caller
    refute Event.fingerprint(:error, e1, st1) == Event.fingerprint(:error, e2, st2)
  end
end
