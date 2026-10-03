IO.inspect(:logger.get_primary_config(), label: "primary")
IO.inspect(Process.info(:c.pid(0,72,0), [:registered_name, :initial_call]), label: "0.72")
IO.inspect(Application.get_env(:logger, :handle_sasl_reports), label: "handle_sasl_reports")
