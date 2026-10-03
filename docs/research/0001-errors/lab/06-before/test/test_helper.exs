# silence the console; tests use their own handlers
:logger.update_handler_config(:default, :level, :none)
ExUnit.start(exclude: [:bench])
