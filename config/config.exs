import Config

if config_env() == :test do
  config :blackbox,
    in_app: [:blackbox],
    scrub_keys: ["board_key"],
    scrub_patterns: ["/b/([^:/?#\\s][^/?#\\s]*)"]

  config :logger, level: :debug

  config :blackbox, Blackbox.TestRepo,
    url: System.get_env("DATABASE_URL", "postgres://postgres@localhost/blackbox_test"),
    pool_size: 5,
    log: false

  config :blackbox, Blackbox.DownRepo,
    url: "postgres://postgres@localhost:4399/blackbox_test",
    pool_size: 1,
    log: false,
    queue_target: 50,
    queue_interval: 200,
    backoff_min: 200,
    backoff_max: 1000
end
