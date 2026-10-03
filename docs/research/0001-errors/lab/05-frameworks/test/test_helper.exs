:inets.start()
# keep the console quiet; our capture handler has its own level :all
:logger.set_handler_config(:default, :level, :none)
IO.puts("primary logger level: #{inspect(:logger.get_primary_config().level)}")
ExUnit.start(exclude: [:bench])
