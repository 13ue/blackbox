require Logger
:logger.update_handler_config(:default, :level, :info)
n = 500_000
med = fn f -> f.(); runs = for _ <- 1..5, do: elem(:timer.tc(f), 0); Enum.at(Enum.sort(runs), 2) * 1000 / n end
:logger.set_primary_config(:level, :info)
IO.puts("primary :info: #{Float.round(med.(fn -> for i <- 1..n, do: Logger.debug("step #{i}", user_id: 42) end), 1)} ns per Logger.debug")
:logger.set_primary_config(:level, :debug)
IO.puts("primary :debug: #{Float.round(med.(fn -> for i <- 1..n, do: Logger.debug("step #{i}", user_id: 42) end), 1)} ns")
Logger.put_process_level(self(), :info)
IO.puts("primary :debug, this process muted to :info: #{Float.round(med.(fn -> for i <- 1..n, do: Logger.debug("step #{i}", user_id: 42) end), 1)} ns")
