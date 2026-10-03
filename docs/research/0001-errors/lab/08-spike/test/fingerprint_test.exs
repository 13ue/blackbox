defmodule Spike.FingerprintTest do
  use ExUnit.Case, async: false
  alias Spike.Event

  defp compile(src, pad) do
    [{mod, _}] = Code.compile_string(String.duplicate("\n", pad) <> src, "fp_#{pad}.ex")
    mod
  end

  defp stack_of(fun) do
    try do
      fun.()
    rescue
      e -> {e, __STACKTRACE__}
    end
  end

  @src """
  defmodule FpMod do
    def run(x), do: step(x)
    def step(x), do: Enum.map([x], fn y -> raise "bad \#{y}" end)
  end
  """

  test "08-9: the same bug shifted by 40 lines keeps its fingerprint, although the stack lines differ" do
    mod = compile(@src, 0)
    {e1, st1} = stack_of(fn -> mod.run(1) end)
    :code.purge(mod); :code.delete(mod)
    mod = compile(@src, 40)
    {e2, st2} = stack_of(fn -> mod.run(2) end)
    refute st1 == st2
    assert Event.fingerprint(:error, e1, st1) == Event.fingerprint(:error, e2, st2)
  end

  test "08-10: an extra anonymous function earlier in the module keeps the fingerprint (fun index stripped)" do
    src2 = String.replace(@src, "def run(x), do: step(x)", "def run(x), do: (fn -> :ok end).() && step(x)")
    {e1, st1} = stack_of(fn -> compile(@src, 0).run(1) end)
    {e2, st2} = stack_of(fn -> compile(src2, 0).run(1) end)
    assert Enum.any?(st1, fn {_, f, _, _} -> Atom.to_string(f) =~ "-fun-" end)
    assert Event.fingerprint(:error, e1, st1) == Event.fingerprint(:error, e2, st2)
  end

  test "08-11: a different raising function or exception type changes the fingerprint" do
    {e, st} = stack_of(fn -> compile(@src, 0).run(1) end)
    other = String.replace(@src, "def step(x)", "def step2(x)") |> String.replace("do: step(x)", "do: step2(x)")
    {e2, st2} = stack_of(fn -> compile(other, 0).run(1) end)
    refute Event.fingerprint(:error, e, st) == Event.fingerprint(:error, e2, st2)
    refute Event.fingerprint(:error, e, st) == Event.fingerprint(:error, %ArgumentError{}, st)
  end

  test "08-12: log messages with different ids, pids and uuids share a fingerprint" do
    a = Event.fingerprint(:log, "user 12 failed at #PID<0.1.0> 3f1c2a9e-0b7e-4c1f-9a3e-1d2c3b4a5f60", [])
    b = Event.fingerprint(:log, "user 993 failed at #PID<0.77.0> aa1c2a9e-0b7e-4c1f-9a3e-1d2c3b4a5f61", [])
    assert a == b
    refute a == Event.fingerprint(:log, "order 12 failed", [])
  end

  test "08-13: exit reasons with pids and refs share a fingerprint by shape" do
    a = Event.fingerprint(:exit, {:timeout, {GenServer, :call, [self(), :x, 5000]}}, [])
    b = Event.fingerprint(:exit, {:timeout, {GenServer, :call, [spawn(fn -> :ok end), :y, 100]}}, [])
    assert a == b
  end
end
