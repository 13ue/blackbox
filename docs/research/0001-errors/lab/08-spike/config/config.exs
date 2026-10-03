import Config
config :spike, ecto_repos: [Spike.Repo]
config :spike, Spike.Repo,
  database: "lab_0031_08", username: "postgres", hostname: "localhost", port: 5432,
  pool_size: 5, log: false
# A repo pointed at a port where nothing listens: "the DB is down".
config :spike, Spike.DownRepo,
  database: "lab_0031_08", username: "postgres", hostname: "localhost", port: 4399,
  pool_size: 1, log: false, queue_target: 50, queue_interval: 200, backoff_min: 200, backoff_max: 1000
config :logger, level: :debug
