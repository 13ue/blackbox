# The console's crash reports are noise here; the console test adds its own.
:logger.remove_handler(:default)
ExUnit.start(exclude: [:flood], max_cases: 1)
# ExUnit sets backtrace_depth to 20 after Blackbox set 32 (04-34).
:erlang.system_flag(:backtrace_depth, 32)
