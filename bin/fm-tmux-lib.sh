#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e) and extracts the real typed content with the
# shared, fleet-wide fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops
# every de-emphasised run - dim/faint (SGR 2) AND a dark/muted truecolor
# foreground - so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that de-emphasises placeholder/ghost text
# benefits, and the herdr adapter routes through the same owner (task
# afk-herdr-false-pending), so the two backends cannot drift.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
#
# State source (FM_STATE_SOURCE, default unset = tmux): when set to `herdr`, the
# DETECTION predicates below (fm_pane_is_busy, fm_pane_input_pending, and the new
# fm_pane_needs_human) draw agent state from herdr's native socket API
# (bin/fm-herdr-lib.sh) instead of scraping tmux. With the flag unset the herdr
# lib is never even sourced and every predicate takes its original tmux path
# verbatim, so default behavior is byte-for-byte identical. A pane herdr is not
# tracking (status `unknown`) transparently degrades to the tmux scrape via
# FM_HERDR_UNKNOWN_FALLBACK. SUBMIT is deliberately NOT wired to herdr: the
# swallowed-Enter reality of agent TUIs keeps fm_tmux_composer_state / submit on
# tmux (see bin/fm-herdr-lib.sh header). The seam is intentionally thin — the
# event-driven watcher loop and the submit rewrite are separate follow-ups.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer-content classification (empty|pending|unknown, and the fleet-wide
# rule that a BARE shell prompt glyph is a dead shell, not an empty agent
# composer) is NOT owned here: it is the shared bin/fm-composer-lib.sh, sourced
# below and reused by every backend adapter so the decision cannot drift.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73).
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a busy footer, an empty agent composer, or
#             only de-emphasised ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error), OR the cursor line is a
#             bare shell prompt (`$`/`%`/`#`/`>`) - a dead shell, not an agent
#             composer, so NOT a safe injection target. The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E). The bordered flag (a genuine composer box) is
# read from the PLAIN row (fm_composer_strip_ansi keeps ghost text so the box
# border is still visible), while the real-typed CONTENT is extracted with the
# shared fm_composer_strip_ghost so dim/faint AND dark-truecolor ghost text drops
# out before classification (grok's dark box border drops with the ghost, which
# is why the bordered flag is read from the plain row, not the ghost-stripped
# one). Both are internal only, never surfaced. The detector strips the harness's
# box-drawing composer borders ("│ … │", heavy "┃", or a plain ASCII "|") using
# literal-string substitution (bash 3.2 safe, locale-independent - no \u escapes,
# no multibyte character classes), and delegates the empty/pending/unknown
# decision to the shared owner fm_composer_classify_content
# (bin/fm-composer-lib.sh). The bordered flag is what lets a bordered `│ > │`
# (claude's own idle composer) read empty while a bare, unbordered `$ ` dead-shell
# prompt reads unknown.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw plain stripped bordered=0
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  # bordered: from the plain row (borders survive an all-ANSI strip).
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  case "$plain" in
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  # content: from the ghost-stripped row (real typed text only).
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A busy footer landing on the cursor line is not pending input (tmux-specific:
  # only tmux captures the raw cursor row, which may BE the footer).
  if [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  fm_composer_classify_content "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-}" insensitive "$plain"
}

# ---- herdr state-source seam (default OFF) --------------------------------
# These helpers are inert unless FM_STATE_SOURCE=herdr. They let the detection
# predicates below draw native agent state from bin/fm-herdr-lib.sh while keeping
# the tmux path byte-for-byte identical when the flag is unset.

# _fm_herdr_lib_loaded: source bin/fm-herdr-lib.sh once, from next to this file.
# Returns 1 (so callers fall back to tmux) if herdr is unusable — binary or lib
# missing. Sourcing is lazy: it only happens under the flag (see _fm_herdr_state).
_fm_herdr_lib_loaded() {
  command -v "${HERDR_BIN:-herdr}" >/dev/null 2>&1 || return 1
  command -v fm_herdr_agent_status >/dev/null 2>&1 && return 0
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  [ -r "$d/fm-herdr-lib.sh" ] || return 1
  # shellcheck source=bin/fm-herdr-lib.sh
  . "$d/fm-herdr-lib.sh"
}

# _fm_tmux_status_word: a herdr-style status word derived purely from the tmux
# busy scrape — `working` if the pane shows a busy footer, else `idle`. Wired as
# the default FM_HERDR_UNKNOWN_FALLBACK so a pane herdr does not yet track (the
# startup/attach window, or a non-integrated harness) degrades to tmux. Calls the
# RAW tmux impl, never the dispatching predicate, so it cannot recurse.
_fm_tmux_status_word() {  # <target>
  if _fm_tmux_pane_is_busy_impl "$1"; then printf 'working'; else printf 'idle'; fi
}

# _fm_herdr_state: the resolved herdr status for <target> (idle|working|blocked|
# done) with the tmux fallback wired in, or an EMPTY string when the herdr source
# is off or unusable — in which case the caller uses its tmux path unchanged.
# The leading guard is what guarantees the default path is untouched: with
# FM_STATE_SOURCE unset this returns '' before herdr is ever probed or sourced.
_fm_herdr_state() {  # <target>
  [ "${FM_STATE_SOURCE:-}" = herdr ] || { printf ''; return 0; }
  _fm_herdr_lib_loaded || { printf ''; return 0; }
  FM_HERDR_UNKNOWN_FALLBACK="${FM_HERDR_UNKNOWN_FALLBACK:-_fm_tmux_status_word}" \
    fm_herdr_agent_status "$1"
}

# _fm_tmux_pane_is_busy_impl: the original tmux busy detector (unchanged body).
# fm_pane_is_busy dispatches to this when the herdr source is off; the fallback
# adapter above also calls it directly.
_fm_tmux_pane_is_busy_impl() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}
# ---------------------------------------------------------------------------

# fm_pane_input_pending: 0 (pending) if it is NOT safe to inject — the cursor line
# holds real unsubmitted text, 1 otherwise. An unreadable pane is treated as NOT
# pending (fail-safe: the same bias the old daemon used — an unknown pane defers
# nothing here).
# Under FM_STATE_SOURCE=herdr: a `working` or `blocked` agent is definitively
# not-injectable, so it reports pending directly; an `idle`/`done` agent is
# quiescent but herdr cannot see human-typed text, so the tmux composer check
# still decides that case; an untracked pane ('') takes the tmux path unchanged.
fm_pane_input_pending() {  # <target>
  case "$(_fm_herdr_state "$1")" in
    working|blocked) return 0 ;;
    idle|done)       if [ "$(fm_tmux_composer_state "$1")" = pending ]; then return 0; else return 1; fi ;;
  esac
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_needs_human: 0 iff the agent is parked on an in-turn approval prompt
# (herdr `blocked`) — the native needs-decision signal. This is a herdr-only
# capability: with the state source off (or herdr not tracking the pane) it
# returns 1 (false), because the tmux scrape has no reliable equivalent.
fm_pane_needs_human() {  # <target>
  [ "$(_fm_herdr_state "$1")" = blocked ]
}

# fm_pane_is_busy: 0 if the agent is mid-turn. Under FM_STATE_SOURCE=herdr this is
# herdr's native `working`; otherwise it scans a 40-line tail for a busy footer
# like fm-watch.sh. With the flag unset, _fm_herdr_state returns '' and this is
# byte-for-byte the original tmux detector.
fm_pane_is_busy() {  # <target>
  case "$(_fm_herdr_state "$1")" in
    working)           return 0 ;;
    idle|done|blocked) return 1 ;;
  esac
  _fm_tmux_pane_is_busy_impl "$1"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
