import Config

# Telemetry stays opt-in even in dev — keep parity with the default.
# Override locally if you want to inspect events while iterating.
config :xqlite, :telemetry_enabled, false
