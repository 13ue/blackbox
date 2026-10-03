import sys, subprocess, shutil
ORIG = "../08-spike/"
M = {
 "M10 line in fingerprint": ("lib/spike/event.ex", "|> Enum.map(fn {m, f, a, _} -> {m, strip_fun(f), if(is_list(a), do: length(a), else: a)} end)", "|> Enum.map(fn {m, f, a, loc} -> {m, strip_fun(f), if(is_list(a), do: length(a), else: a), loc[:line]} end)", "test/fingerprint_test.exs"),
 "M11 no stdlib skip": ("lib/spike/event.ex", "|> Enum.reject(fn {m, _, _, _} -> MapSet.member?(skip_modules(), m) end)", "|> Enum.reject(fn _ -> false end)", "test/fingerprint_test.exs test/capture_test.exs"),
 "M12 exit shape ignores tuple tag": ("lib/spike/event.ex", 'defp shape(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)), do: "{#{inspect(elem(t, 0))}, _}"', 'defp shape(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)), do: inspect(t)', "test/fingerprint_test.exs test/capture_test.exs"),
}
out = open("../../logs/10-mutations.log", "a")
for name, (f, old, new, tests) in M.items():
    src = open(ORIG + f).read()
    assert old in src, (name, old)
    open(f, "w").write(src.replace(old, new))
    r = subprocess.run(f"MIX_ENV=test mix test {tests} 2>&1", shell=True, capture_output=True, text=True).stdout
    res = [l for l in r.splitlines() if l.startswith("Result")]
    fails = [l.strip() for l in r.splitlines() if ") test 08-" in l]
    line = f"{name} [{f}] -> {res} red: {fails}"
    print(line); out.write(line + "\n"); out.flush()
    shutil.copy(ORIG + f, f)
