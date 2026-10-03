Code.prepend_path(hd(Path.wildcard(Path.join(:code.root_dir(), "lib/tools-*/ebin"))))
require Logger
:logger.remove_handler(:default)
Spike.Buffer.set_writer(fn _ -> :ok end)
stack = for i <- 1..12, do: {:"Elixir.MyApp.Mod#{i}", :fun, 2, [file: ~c"lib/my_app/mod.ex", line: i]}
event = %{level: :error, msg: {:report, %{label: {:gen_server, :terminate}, last_message: {:call, 1}, state: %{a: 1}}},
          meta: %{pid: self(), crash_reason: {%RuntimeError{message: "x"}, stack}, mfa: {:gen_server, :error_info, 7}}}
for i <- 1..20, do: Spike.crumb("c #{i}")
:tprof.profile(fn -> for i <- 1..2000, do: Logger.error("cost #{i}") end, %{type: :call_time, report: {:total, :measurement}})
:tprof.profile(fn -> for _ <- 1..2000, do: Spike.Event.from_log(event) end, %{type: :call_time, report: {:total, :measurement}})
