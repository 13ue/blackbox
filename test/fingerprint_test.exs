defmodule Blackbox.FingerprintTest do
  use ExUnit.Case, async: false
  alias Blackbox.Event
  alias Blackbox.Fixtures.Sites

  # Modules compiled here belong to no application: they are dependency frames.
  defp compile(src, pad \\ 0, file \\ "fp.ex") do
    [{mod, _}] = Code.compile_string(String.duplicate("\n", pad) <> src, file)
    mod
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end

  defp grab(fun) do
    fun.()
  rescue
    e -> {e, __STACKTRACE__}
  end

  defp fp({e, st}), do: Event.fingerprint(:error, e, st)

  @src """
  defmodule FpMod do
    def run(x), do: step(x)
    def step(x), do: Enum.map([x], fn y -> raise "bad \#{y}" end)
  end
  """

  test "08-9: the same bug shifted by 40 lines keeps its fingerprint" do
    mod = compile(@src)
    a = grab(fn -> mod.run(1) end)
    purge(mod)
    mod = compile(@src, 40)
    b = grab(fn -> mod.run(2) end)
    purge(mod)
    refute elem(a, 1) == elem(b, 1)
    assert fp(a) == fp(b)
  end

  test "M2: a new anonymous function earlier in the SAME function keeps the fingerprint" do
    # The raising fun is -step/1-fun-0- here and -step/1-fun-1- below.
    src2 =
      String.replace(
        @src,
        "def step(x), do: Enum.map([x],",
        "def step(x), do: (fn -> :ok end).() && Enum.map([x],"
      )

    mod = compile(@src)
    a = grab(fn -> mod.run(1) end)
    purge(mod)
    mod = compile(src2)
    b = grab(fn -> mod.run(1) end)
    purge(mod)
    names = fn {_, st} -> for {_, f, _, _} <- st, Atom.to_string(f) =~ "-fun-", do: f end
    refute names.(a) == names.(b)
    assert fp(a) == fp(b)
  end

  test "08-11: a different raising function or exception type changes the fingerprint" do
    mod = compile(@src)
    a = grab(fn -> mod.run(1) end)
    purge(mod)

    mod =
      compile(
        @src
        |> String.replace("def step(x)", "def step2(x)")
        |> String.replace("do: step(x)", "do: step2(x)")
      )

    b = grab(fn -> mod.run(1) end)
    purge(mod)
    refute fp(a) == fp(b)
    refute fp(a) == fp({%ArgumentError{}, elem(a, 1)})
  end

  test "M11: two in-app call sites into the same dependency failure are two issues" do
    # Four dependency frames on top: without the in-app preference, the top 3 decide alone.
    # Remote calls, so the compiler cannot fold the frames into one.
    compile(
      "defmodule FpDepC do\n def three(x), do: {:ok, raise(ArgumentError, \"dep \#{x}\")}\nend"
    )

    compile("defmodule FpDepB do\n def two(x), do: {:ok, FpDepC.three(x)}\nend")
    dep = compile("defmodule FpDep do\n def run(x), do: {:ok, FpDepB.two(x)}\nend")

    a = grab(fn -> Sites.a(dep) end)
    b = grab(fn -> Sites.b(dep) end)
    Enum.each([FpDep, FpDepB, FpDepC], &purge/1)
    assert [FpDepC, FpDepB, FpDep, Sites] = a |> elem(1) |> Enum.take(4) |> Enum.map(&elem(&1, 0))
    assert fp(a) != fp(b)
  end

  test "an exception with no in-app frame falls back to the top frames of any app" do
    a = grab(fn -> Map.fetch!(%{}, :a) end)
    b = grab(fn -> Map.fetch!(%{}, :b) end)
    c = grab(fn -> String.to_integer("x") end)
    assert fp(a) == fp(b)
    refute fp(a) == fp(c)
  end

  test "an empty stack groups by the process label, then its name, then its initial call" do
    by = &Event.fingerprint(:exit, :killed, [], &1)

    assert by.(%{process_label: {:child, :a}}) ==
             by.(%{process_label: {:child, :a}, registered_name: :x})

    refute by.(%{process_label: {:child, :a}}) == by.(%{process_label: {:child, :b}})
    refute by.(%{registered_name: :x}) == by.(%{registered_name: :y})
    refute by.(%{initial_call: {A, :init, 1}}) == by.(%{initial_call: {B, :init, 1}})
  end

  test "logs group by call site, not by text (10-2)" do
    a =
      Event.fingerprint(:log, {:string, "board abcdefgh failed"}, [], %{mfa: {M, :f, 1}, line: 10})

    b =
      Event.fingerprint(:log, {:string, "board zyxwvuts failed"}, [], %{mfa: {M, :f, 1}, line: 10})

    c =
      Event.fingerprint(:log, {:string, "board abcdefgh failed"}, [], %{mfa: {M, :f, 1}, line: 11})

    assert a == b
    refute a == c
  end

  test "08-12: logs without a call site mask every token with a digit" do
    a =
      Event.fingerprint(
        :log,
        {:string, "user 12 failed at #PID<0.1.0> 3f1c2a9e-0b7e-4c1f-9a3e-1d2c3b4a5f60"},
        []
      )

    b =
      Event.fingerprint(
        :log,
        {:string, "user 993 failed at #PID<0.77.0> aa1c2a9e-0b7e-4c1f-9a3e-1d2c3b4a5f61"},
        []
      )

    assert a == b
    refute a == Event.fingerprint(:log, {:string, "order 12 failed"}, [])
  end

  test "08-13: exit reasons with pids and refs share a fingerprint by shape" do
    a = Event.fingerprint(:exit, {:timeout, {GenServer, :call, [self(), :x, 5000]}}, [])

    b =
      Event.fingerprint(
        :exit,
        {:timeout, {GenServer, :call, [spawn(fn -> :ok end), :y, 100]}},
        []
      )

    assert a == b
  end
end
