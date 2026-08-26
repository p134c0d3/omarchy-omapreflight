# Failure injection

This directory is a placeholder for command stubs that would let a scan be run
against synthetic output.

It is deliberately empty. `scripts/demo` takes a different approach: instead of
substituting binaries so the plugin sees invented output, it creates a
genuinely broken plugin on disk and lets the real checks find it.

The distinction matters more than the convenience. A `PATH` shim would mean the
plugin has a mode in which the commands it runs are chosen by something other
than the plugin — a diagnostic tool that can be told what to observe is one
whose output cannot be trusted, and the mechanism would exist in shipped code
whether or not anyone meant to use it.

Everything that can be exercised without executing anything is covered by the
pure-module tests in the parent directory, against real command output captured
from a live machine (`fixtures/CapturedOutput.js`). What is left — how a FAIL
renders, how the readiness verdict reads — needs a real fault, which is what
`scripts/demo` provides and `scripts/demo --clean` removes.
