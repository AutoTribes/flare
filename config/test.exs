import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :flare, Flare.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "db",
  database: "flare_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Use DB index 1 to isolate tests from dev's Redis data
config :flare, :redis_url, "redis://redis:6379/1"

config :flare, Oban, testing: :manual

# We run a real server during test so end-to-end (e2e) tests can exercise
# the SDK over real HTTP, including live SSE streaming.
config :flare, FlareWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8dg1p6Lllu3u/oDVkXOLzzTsjhCUkrY+HVg6QV326jdPRzSdRtrtzKVjrGl+MNYR",
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
