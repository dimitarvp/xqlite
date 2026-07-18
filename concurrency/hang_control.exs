# TEETH for the HANG classifier (Probe 4). This process deliberately never
# terminates. The orchestrator runs it under a SHORT `timeout` and REQUIRES the
# timeout to fire (exit 124) — proving that a genuinely non-terminating probe
# is caught and classified HANG, never left to run forever. A hang detector
# that never trips is worthless.
IO.puts("HANG_CONTROL parking forever (expect the orchestrator timeout to fire)")
Process.sleep(:infinity)
