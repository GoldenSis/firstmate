#!/usr/bin/env bash
# Exercises fm-herdr-lib.sh against a live herdr server. Self-contained: starts a
# throwaway server, drives a pane, asserts every primitive, tears everything down.
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/fm-herdr-lib.sh
. "$DIR/../bin/fm-herdr-lib.sh"

PASS=0; FAIL=0
ok()  { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-34s got=%s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  FAIL  %-34s want=%s got=%s\n' "$1" "$2" "$3"; fi; }
report() { herdr pane report-agent "$P" --source test --agent claude --state "$1" >/dev/null 2>&1; }

echo "### starting throwaway herdr server"
herdr server >/tmp/herdr-test.log 2>&1 &
sleep 3
# Unique agent name so a leftover pane from a prior run (herdr sessions persist
# across server restarts) can't cause an agent_name_taken collision that yields an
# empty pane id and cascades every assertion to fail.
AGENT="crew_$$"
# interactive shell pane so `pane run` echoes visibly
START=$(herdr agent start "$AGENT" --split right -- bash --norc -i 2>&1)
P=$(printf '%s' "$START" | grep -oE '"pane_id":"[^"]+"' | head -1 | cut -d'"' -f4)
echo "### pane = $P"
sleep 1

echo
echo "### A. native status read-back (agent PUSHES state; lib reads it — no scraping)"
report working; ok "status after report working"  working "$(fm_herdr_agent_status "$P")"
report idle;    ok "status after report idle"     idle    "$(fm_herdr_agent_status "$P")"
report blocked; ok "status after report blocked"  blocked "$(fm_herdr_agent_status "$P")"

echo
echo "### B. fm_herdr_pane_is_busy (replaces busy-footer grep)"
report working; if fm_herdr_pane_is_busy "$P"; then ok "is_busy when working" yes yes; else ok "is_busy when working" yes no; fi
report idle;    if fm_herdr_pane_is_busy "$P"; then ok "is_busy when idle"    no  yes; else ok "is_busy when idle"    no  no;  fi

echo
echo "### C. fm_herdr_ready_for_input (replaces empty/pending composer classifier)"
report idle;    if fm_herdr_ready_for_input "$P"; then ok "ready when idle"    yes yes; else ok "ready when idle"    yes no; fi
report blocked; if fm_herdr_ready_for_input "$P"; then ok "ready when blocked" yes yes; else ok "ready when blocked" yes no; fi
report working; if fm_herdr_ready_for_input "$P"; then ok "ready when working" no  yes; else ok "ready when working" no  no;  fi

echo
echo "### D. event-driven wait (replaces fm-watch.sh poll loop + .seen/.stale markers)"
report working
T0=$(date +%s%N)
( RESULT=$(fm_herdr_wait_done "$P" 10000); echo "$RESULT" > /tmp/herdr-wait.out ) &
WPID=$!
sleep 1                      # wait is blocking on 'working'...
report idle                  # <- the transition an agent's integration would push
wait $WPID
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 1000000 ))
ok "wait_done result" "done" "$(cat /tmp/herdr-wait.out)"
if [ "$MS" -lt 2500 ]; then ok "wait unblocked promptly (${MS}ms)" fast fast; else ok "wait unblocked promptly (${MS}ms)" fast slow; fi

echo
echo "### E. fm_herdr_submit — text+Enter as ONE structured op (no swallowed-Enter class)"
herdr pane run "$P" "echo HERDR_SUBMIT_OK" >/dev/null 2>&1
sleep 1
OUT=$(herdr pane read "$P" --source recent --lines 40 2>/dev/null)
if printf '%s' "$OUT" | grep -q "HERDR_SUBMIT_OK"; then ok "pane run delivered text+Enter" yes yes; else ok "pane run delivered text+Enter" yes no; fi
# confirm path: after a send, an agent that starts working confirms the submit landed
report idle
( SR=$(fm_herdr_submit "$P" "echo second" 4000); echo "$SR" > /tmp/herdr-submit.out ) &
SPID=$!
sleep 1
report working               # <- agent reacts to the submitted prompt
wait $SPID
ok "submit confirmed by transition" submitted "$(cat /tmp/herdr-submit.out)"

echo
echo "### teardown"
herdr pane close "$P" >/dev/null 2>&1   # drop the pane so its name/state can't leak into the next run
herdr server stop >/dev/null 2>&1; sleep 1
pkill -f "bash --norc -i" 2>/dev/null
rm -f /tmp/herdr-test.log /tmp/herdr-wait.out /tmp/herdr-submit.out
echo
echo "### RESULT: $PASS passed, $FAIL failed"
exit "$FAIL"
