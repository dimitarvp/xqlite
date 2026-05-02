import Config

# Telemetry is opt-in. Set to `true` in your config to compile in
# `:telemetry.execute/3` / `:telemetry.span/3` calls at every event
# site. When `false` (the default), all emission sites compile to
# no-ops — zero overhead, NO calls into `:telemetry` at all. Suited
# for resource-constrained environments (Nerves, embedded, hot loops
# where every nanosecond counts).
#
# This is a COMPILE-TIME flag. Changing it requires `mix compile
# --force` (or a clean rebuild) on xqlite.
config :xqlite, :telemetry_enabled, false

if config_env() != :prod do
  import_config "#{config_env()}.exs"
end
