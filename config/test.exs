import Config

# Tests verify telemetry events are emitted with the documented shape,
# so the test build compiles emission call sites in.
config :xqlite, :telemetry_enabled, true
