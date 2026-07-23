#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# Every real-Herdr test provisions its isolated lab through
# fm_herdr_lab_prepare, which first records the live default session as its
# fleet-state tripwire. A machine with herdr installed but never started has no
# running default session, so no lab can be provisioned at all - that is an
# unconfigured environment, exactly like a missing binary, not a test failure.
# Gate on it so those suites skip cleanly instead of reporting "not ok".
herdr_lab_environment_ready() { # <session>
  command -v herdr >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fm_herdr_lab_fleet_state "$1" >/dev/null 2>&1
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
