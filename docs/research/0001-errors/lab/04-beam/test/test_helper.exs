# keep the console quiet; our capture handler sees everything at level :all
:logger.update_handler_config(:default, :level, :none)
ExUnit.start(max_cases: 1)
