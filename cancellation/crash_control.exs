# A5 teeth — CRASH-classifier control.
#
# The teardown probe's oracle is an exit-code oracle: a real use-after-free /
# double-free / unwind-into-C from cancel racing teardown would abort the VM
# (SIGABRT 134 / SIGSEGV 139), and run.sh classifies any 134/139 as CRASH.
# This control forces exactly such an exit so run.sh proves it DETECTS a crash
# exit — without it the teardown PASS would rest on an untested classifier.
#
# A live NIF UAF cannot be injected from Elixir (the safety is compiled in) and
# no ASan/TSan-instrumented SQLite build is available (Runs 2/4/5), so a forced
# abnormal exit is the achievable teeth for the crash oracle.
IO.puts("PROBE crash-control (forcing abnormal exit 134 to prove the CRASH classifier)")
System.halt(134)
