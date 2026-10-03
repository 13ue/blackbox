import Config

# Fake DSN + fake client: nothing leaves the machine. Collector callbacks
# forward every event to the test process (see test/test_helper.exs).
config :sentry,
  dsn: "http://public@127.0.0.1:4399/1",
  client: Lab01.FakeClient,
  before_send: {Lab01.Collector, :before_send},
  after_send_event: {Lab01.Collector, :after_send},
  environment_name: "lab"

config :logger, level: :debug
