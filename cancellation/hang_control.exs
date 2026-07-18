# A5 teeth — HANG-classifier control.
#
# The teardown probe is bounded by an OS `timeout`. A cancel-vs-teardown
# interleaving that wedged a thread (e.g. a deadlock between the cancel store
# path and the conn Mutex) would never return; run.sh must classify that as
# HANG (rc=124). This control sleeps forever so run.sh proves its timeout leg
# fires and is distinguished from a clean exit.
IO.puts("PROBE hang-control (sleeping forever; the OS timeout must fire -> rc=124)")
Process.sleep(:infinity)
