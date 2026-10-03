import Config

if config_env() == :test do
  config :blackbox, in_app: [:blackbox]
  config :logger, level: :debug
end
