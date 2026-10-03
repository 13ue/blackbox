import Config

config :phoenix, :json_library, Jason

common = [
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  render_errors: [formats: [json: Lab05.ErrorJSON], layout: false],
  pubsub_server: Lab05.PubSub,
  live_view: [signing_salt: "lab05salt"],
  server: true
]

config :lab05, Lab05.Endpoint,
  common ++ [adapter: Bandit.PhoenixAdapter, http: [ip: {127, 0, 0, 1}, port: 4351]]

config :lab05, Lab05.CowboyEndpoint,
  common ++ [adapter: Phoenix.Endpoint.Cowboy2Adapter, http: [ip: {127, 0, 0, 1}, port: 4352]]

config :lab05, Lab05.Repo,
  database: "lab_0031_05",
  username: "postgres",
  hostname: "localhost",
  pool_size: 2,
  log: :debug

config :lab05, ecto_repos: [Lab05.Repo]
