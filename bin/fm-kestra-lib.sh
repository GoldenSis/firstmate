#!/usr/bin/env bash
# fm-kestra-lib.sh - shared, fail-closed helpers for firstmate's Kestra execution seam.
#
# This library is the single owner of five contracts the three seam entrypoints
# (fm-kestra-deploy.sh, fm-kestra-run.sh, fm-kestra-status.sh) all depend on:
#
#   1. Local configuration and the loopback-only endpoint rule.
#   2. Flow-identity resolution against one immutable snapshot of the tracked,
#      unchanged HEAD blobs under kestra/flows/. A flow that is not in that snapshot
#      is not addressable, and a local flow edit stops the seam.
#   3. The M1 static-flow grammar. One parser (fm_kestra_parse_flow) accepts exactly
#      the YAML shape, task types, and input schema M1 supports and emits one
#      validated record stream that every consumer reads. Pebble templating
#      (`{{ }}`, `{% %}`, `{# #}`) is refused everywhere: a permitted task can only
#      carry literal text, so no task can render a secret, an input, or any other
#      server-side value. Unsupported syntax, triggers, and side-effecting task
#      types are refused rather than approximated.
#   4. The deployed-revision record. Deployment records, per flow, the Kestra
#      revision that was verified to carry the reviewed HEAD bytes; a run binds to
#      that revision and refuses when the record is absent, stale, or unverifiable.
#   5. The HTTP gate. Every request goes through fm_kestra_request, which takes a
#      ROLE and refuses any method/path the role does not positively allow. Replay,
#      restart, resume, kill, state override, flow deletion, secrets, and namespace
#      administration are unreachable from every role, so a coding mistake in a
#      caller cannot reach them either. The deploy role builds its own payload from
#      the HEAD snapshot; no caller can hand it a body.
#
# Authority stays outside Kestra. Nothing here lets a flow result approve, merge,
# route, or unlock anything: a Kestra state is evidence that a task ran and nothing
# more.
#
# Version pin. fm_kestra_pinned_version and fm_kestra_pinned_sha256 are the only
# owners of the pinned Kestra Open Source Edition version and the official
# standalone asset's publisher-listed SHA-256. No `latest` tag and no unversioned
# image is supported. Verify a downloaded asset before running it:
#   shasum -a 256 <asset>    # must equal the value fm_kestra_pinned_sha256 prints
#
# Credentials. Kestra OSS authenticates one broad Basic Auth identity, so the
# credential is treated as a disclosure risk throughout: it is read from gitignored
# local config, handed to curl through a mode-0600 temp config file that is removed
# on exit, and never placed in argv, in an exported environment variable curl
# inherits by name, or in any diagnostic this library prints. Curl ignores user
# config, bypasses every proxy, and treats HTTP errors as failures with their
# response body retained as a diagnostic.
#
# Sourced, not executed. Callers source it and then call fm_kestra_load_config.
# shellcheck shell=bash

# Guard against double-sourcing.
if [ -n "${FM_KESTRA_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_KESTRA_LIB_SOURCED=1

FM_KESTRA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_KESTRA_ROOT="$(cd "$FM_KESTRA_LIB_DIR/.." && pwd)"
FM_KESTRA_HOME="${FM_HOME:-$FM_KESTRA_ROOT}"

# The pinned target. Callers print these rather than re-spelling literals.
fm_kestra_pinned_version() { printf '%s\n' '1.3.34'; }
fm_kestra_pinned_sha256() {
  printf '%s\n' 'de846ac42e2b35a2e55301d01335de6ea30eab77fd69570f238e06ea28149a4b'
}

fm_kestra_die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-2}"
}

# Record fields are separated by US (0x1f), not a tab: bash treats a tab as IFS
# whitespace and would silently collapse consecutive empty fields.
FM_KESTRA_US=$(printf '\037')

# --- tracked flow directory -------------------------------------------------

# The flow source directory is always resolved from the CODE root, never from
# FM_HOME: flows are shared tracked material that Git reviews, not per-home local
# state that an operator can vary.
fm_kestra_flows_dir() {
  printf '%s\n' "$FM_KESTRA_ROOT/kestra/flows"
}

FM_KESTRA_SNAPSHOT_FILES=()
FM_KESTRA_SNAPSHOT_SOURCES=()
FM_KESTRA_SNAPSHOT_BLOBS=()
FM_KESTRA_SNAPSHOT_HEAD=""

fm_kestra_assert_flows_unchanged() {
  local head=$1 untracked
  git -C "$FM_KESTRA_ROOT" diff --quiet "$head" -- kestra/flows \
    || fm_kestra_die "tracked flow sources have local changes; commit them before using the seam"
  untracked=$(git -C "$FM_KESTRA_ROOT" ls-files --others --exclude-standard -- 'kestra/flows/*.yaml')
  [ -z "$untracked" ] \
    || fm_kestra_die "untracked flow sources are present; commit or remove them before using the seam"
}

# fm_kestra_snapshot_flow_files: populate parallel arrays with immutable copies of
# the current HEAD flow blobs, their canonical source paths, and their Git blob ids.
# The blob id is the content identity the deployed-revision record binds to.
fm_kestra_snapshot_flow_files() {
  local head relative metadata mode type object snapshot current_head
  FM_KESTRA_SNAPSHOT_FILES=()
  FM_KESTRA_SNAPSHOT_SOURCES=()
  FM_KESTRA_SNAPSHOT_BLOBS=()
  FM_KESTRA_SNAPSHOT_HEAD=""
  [ -d "$(fm_kestra_flows_dir)" ] || fm_kestra_die "flow directory is unavailable: $(fm_kestra_flows_dir)"
  head=$(git -C "$FM_KESTRA_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || fm_kestra_die "flow allow-list is unavailable from Git HEAD"
  fm_kestra_assert_flows_unchanged "$head"

  while IFS=$'\t' read -r metadata relative; do
    [ -n "$relative" ] || continue
    read -r mode type object <<< "$metadata"
    case "$relative" in
      kestra/flows/*.yaml) : ;;
      *) continue ;;
    esac
    case "${relative#kestra/flows/}" in
      */*) fm_kestra_die "tracked flow source must be directly under kestra/flows: $relative" ;;
    esac
    [ "$type" = blob ] && [ "$mode" != 120000 ] \
      || fm_kestra_die "tracked flow source is not a regular file: $relative"
    fm_kestra_tempfile flow snapshot \
      || fm_kestra_die "could not snapshot tracked flow: $relative" 1
    git -C "$FM_KESTRA_ROOT" cat-file blob "$object" > "$snapshot" \
      || fm_kestra_die "could not read tracked flow from Git HEAD: $relative" 1
    FM_KESTRA_SNAPSHOT_FILES+=("$snapshot")
    FM_KESTRA_SNAPSHOT_SOURCES+=("$FM_KESTRA_ROOT/$relative")
    FM_KESTRA_SNAPSHOT_BLOBS+=("$object")
  done < <(git -C "$FM_KESTRA_ROOT" ls-tree -r "$head" -- kestra/flows | LC_ALL=C sort -k2)

  fm_kestra_assert_flows_unchanged "$head"
  current_head=$(git -C "$FM_KESTRA_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || fm_kestra_die "flow allow-list is unavailable from Git HEAD"
  [ "$current_head" = "$head" ] \
    || fm_kestra_die "Git HEAD changed while flow sources were being prepared"
  FM_KESTRA_SNAPSHOT_HEAD=$head
}

fm_kestra_ensure_flow_snapshot() {
  if [ -z "$FM_KESTRA_SNAPSHOT_HEAD" ]; then
    fm_kestra_snapshot_flow_files
  fi
}

# --- the M1 static-flow grammar ----------------------------------------------
#
# fm_kestra_parse_flow <file> [source-name] is the ONE parser. It prints one
# `<source>: <problem>` line per problem to stderr and exits non-zero if any were
# found; on success it prints validated records to stdout, US-separated:
#   flow  | id | namespace
#   input | id | type | required | min | max | values (comma-joined) | validator
#   task  | id | type
#
# The grammar is deliberately small, and everything outside it is refused rather
# than approximated, because an adapter that silently skipped a construct it did
# not understand would under-validate and call it a pass:
#   - two-space indentation, no tabs, no flow style, no anchors, aliases, merge
#     keys, directives, document markers, single quotes, or inline comments;
#   - no Pebble templating anywhere in the file: every task field is literal text;
#   - top-level keys: id, namespace, labels, inputs, tasks - nothing else, and
#     `triggers` is refused by name because executions start only through the run
#     adapter;
#   - labels: exactly `system.readOnly: "true"`;
#   - inputs: INT (min/max), SELECT (block-list values), STRING (validator in the
#     regex subset below), plus required and a double-quoted description;
#   - tasks: exactly the M1-safe core task types with exactly their supported
#     fields; text fields are double-quoted literals from a printable subset;
#     `content: |` is the only block scalar; `then`, `else`, and `tasks` are the
#     only containers; `retry` is the only nested mapping.
#
# Validator regex subset. A STRING validator is pre-checked locally with jq using
# Unicode characters, full-string anchors, and Java-compatible dot semantics.
# Kestra evaluates the same pattern with Java's Pattern.matches. The supported
# grammar is `^` ... `$` anchors, literal [A-Za-z0-9_-], dot, bracket expressions of
# [A-Za-z0-9_-] and their ranges, groups, alternation, and the quantifiers
# `* + ? {n} {n,m}`. No backslash, so no escapes or classes, and no `(?` extensions.

fm_kestra_parse_flow() {
  local file=$1 source=${2:-$1}
  awk -v source="$source" '
    BEGIN {
      US = sprintf("%c", 31)
      problems = 0; section = ""; block = -1
      SQ = sprintf("%c", 39)
      TEXT_RE = "^\"[A-Za-z0-9 _.,:;=()/+-]+\"$"
      ALLOWED["io.kestra.plugin.core.debug.Return"] = "format"
      ALLOWED["io.kestra.plugin.core.execution.Fail"] = "errorMessage retry"
      ALLOWED["io.kestra.plugin.core.flow.If"] = "condition then else"
      ALLOWED["io.kestra.plugin.core.flow.Parallel"] = "tasks"
      ALLOWED["io.kestra.plugin.core.flow.Sequential"] = "tasks"
      ALLOWED["io.kestra.plugin.core.log.Log"] = "message"
      ALLOWED["io.kestra.plugin.core.storage.Write"] = "extension content"
    }
    function fail(message) {
      print source ": " message > "/dev/stderr"
      problems = 1
    }
    function indent(line) { match(line, /^ */); return RLENGTH }
    function trim(value) {
      sub(/^[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
      return value
    }
    function key_of(line, value) {
      value = line
      sub(/^ *(- )?/, "", value)
      sub(/:.*/, "", value)
      return value
    }
    function value_of(line, value) {
      value = line
      sub(/^[^:]*:/, "", value)
      return trim(value)
    }
    function is_ident(value) { return value ~ /^[A-Za-z0-9_-]+$/ }
    function is_text(value) { return value ~ TEXT_RE }
    function is_bool(value) { return value ~ /^(true|false)$/ }
    function is_int(value) { return value ~ /^-?[0-9]+$/ }
    function is_select_value(value, lower) {
      if (value !~ /^[A-Za-z][A-Za-z0-9_ -]*$/) return 0
      if (value ~ /  / || value ~ / $/) return 0
      lower = tolower(value)
      if (lower ~ /^(true|false|null|yes|no|on|off|y|n)$/) return 0
      return 1
    }
    # The ERE/Java-common regex subset described in the header, checked character
    # by character so no engine-specific construct slips through by omission.
    function is_validator(value,   i, n, c, inb, depth, prev, braces) {
      n = length(value)
      if (n < 3 || substr(value, 1, 1) != "^" || substr(value, n, 1) != "$") return 0
      inb = 0; depth = 0; prev = "("
      for (i = 2; i < n; i++) {
        c = substr(value, i, 1)
        if (inb) {
          if (c == "]") { inb = 0; prev = "]"; continue }
          if (c ~ /[A-Za-z0-9_-]/) continue
          return 0
        }
        if (c == "[") {
          if (substr(value, i + 1, 1) ~ /[\]^]/) return 0
          inb = 1; continue
        }
        if (c == "(") { depth++; prev = "("; continue }
        if (c == ")") { if (depth == 0 || prev == "(" || prev == "|") return 0; depth--; prev = ")"; continue }
        if (c == "|") { if (prev == "(" || prev == "|") return 0; prev = "|"; continue }
        if (c ~ /[*+?{]/) {
          if (prev == "(" || prev == "|" || prev == "q") return 0
          if (c == "{") {
            braces = substr(value, i)
            if (match(braces, /^\{[0-9]+(,[0-9]*)?\}/) != 1) return 0
            i = i + RLENGTH - 1
          }
          prev = "q"; continue
        }
        if (c ~ /[A-Za-z0-9_.-]/) { prev = "c"; continue }
        return 0
      }
      if (inb || depth != 0 || prev == "(" || prev == "|") return 0
      return 1
    }
    function field_allowed(type, key,   n, i, list) {
      if (key == "id" || key == "type") return 1
      if (!(type in ALLOWED)) return 0
      n = split(ALLOWED[type], list, " ")
      for (i = 1; i <= n; i++) if (list[i] == key) return 1
      return 0
    }
    function clear_from(level,   i) {
      for (i in ctx) if ((i + 0) >= level) delete ctx[i]
    }
    function owner_kind(level) {
      if (!((level - 2) in ctx)) return ""
      split(ctx[level - 2], parts, SUBSEP)
      return parts[1]
    }
    function owner_task(level) {
      split(ctx[level - 2], parts, SUBSEP)
      return parts[2]
    }

    /^[ \t]*$/ { next }
    {
      raw = $0
      level = indent(raw)
      if (block >= 0) {
        if (level > block) {
          if (raw ~ /\t/) fail("tabs are not supported in flow YAML")
          else if (raw ~ /\{\{|\{%|\{#/) fail("Pebble templating is not permitted in an M1 static flow")
          else {
            line = raw
            sub(/^ +/, "", line)
            if (line !~ /^[A-Za-z0-9 _.,:;=()\/+-]*$/) {
              fail("content block lines must be literal text from the supported character set")
            }
          }
          content_lines[block_task]++
          next
        }
        block = -1
      }
    }
    /^[ \t]*#/ { next }
    {
      if (raw ~ /\t/) { fail("tabs are not supported in flow YAML"); next }
      if (raw ~ /\{\{|\{%|\{#|\}\}|%\}/) {
        fail("Pebble templating is not permitted in an M1 static flow")
        next
      }
      if (raw ~ /#/) { fail("inline comments are not supported"); next }
      if (index(raw, SQ)) { fail("single-quoted scalars are not supported"); next }
      if (level % 2 != 0) { fail("indentation must use two-space levels"); next }
      if (raw ~ /<<:/ || raw ~ /&/ || raw ~ /:[ ]*\*/ || raw ~ /^ *- *\*/) {
        fail("YAML anchors, aliases, and merge keys are not supported")
        next
      }
      if (raw ~ /:[ ]*[\[{]/ || raw ~ /^ *- *[\[{]/) {
        fail("flow-style mappings and sequences are not supported")
        next
      }
      if (raw ~ /^ *(---|\.\.\.)[ ]*$/ || raw ~ /^ *%/) {
        fail("YAML directives and document markers are not supported inside a flow")
        next
      }
      if (raw ~ /[ \t]$/) { fail("trailing whitespace is not supported"); next }
    }
    level == 0 {
      clear_from(0)
      section = ""
      if (raw !~ /^[A-Za-z][A-Za-z0-9]*:/) { fail("unsupported top-level YAML form"); next }
      key = key_of(raw)
      value = value_of(raw)
      if (seen_top[key]++) fail("duplicate top-level key: " key)
      if (key == "id") {
        if (!is_ident(value)) fail("top-level id must be an unquoted [A-Za-z0-9_-]+ scalar")
        flow_id = value
      } else if (key == "namespace") {
        if (value !~ /^[A-Za-z0-9._-]+$/) fail("top-level namespace must be an unquoted [A-Za-z0-9._-]+ scalar")
        flow_ns = value
      } else if (key == "labels" || key == "inputs" || key == "tasks") {
        if (value != "") fail("top-level " key " must use the supported block form")
        section = key
        if (key == "tasks") ctx[0] = "container" SUBSEP 0 SUBSEP "tasks"
      } else if (key == "triggers") {
        fail("top-level triggers are refused because executions must start through the run adapter")
      } else {
        fail("unsupported top-level key: " key)
      }
      next
    }
    section == "" { fail("content outside a supported top-level section"); next }
    section == "labels" {
      if (level != 2 || raw !~ /^  system\.readOnly: ("true"|true)$/) {
        fail("labels must contain only system.readOnly: \"true\"")
      } else {
        readonly = 1
      }
      next
    }
    section == "inputs" {
      if (level == 2) {
        in_values = 0
        if (raw !~ /^  - id: /) { fail("inputs must be a block list of items that begin with id"); next }
        input_count++
        value = value_of(raw)
        if (!is_ident(value)) fail("input id must be an unquoted [A-Za-z0-9_-]+ scalar")
        if (seen_input_id[value]++) fail("duplicate input id: " value)
        input_id[input_count] = value
        next
      }
      if (level == 4 && input_count > 0 && raw ~ /^    [A-Za-z][A-Za-z]*:/) {
        key = key_of(raw)
        value = value_of(raw)
        in_values = 0
        if (input_field[input_count, key]++) fail("duplicate input key: " key)
        if (key == "type") {
          if (value !~ /^(INT|SELECT|STRING)$/) fail("unsupported input type: " value)
          input_type[input_count] = value
        } else if (key == "required") {
          if (!is_bool(value)) fail("input required must be true or false")
          input_required[input_count] = value
        } else if (key == "min" || key == "max") {
          if (!is_int(value)) fail("input " key " must be an unquoted integer")
          input_bound[input_count, key] = value
        } else if (key == "validator") {
          if (!is_validator(value)) {
            fail("input " input_id[input_count] " uses a validator outside the ERE/Java-common regex subset: " value)
          }
          input_validator[input_count] = value
        } else if (key == "description") {
          if (!is_text(value)) fail("input description must be a double-quoted literal")
        } else if (key == "values") {
          if (value != "") fail("SELECT values must use the supported block-list form")
          in_values = 1
        } else {
          fail("unsupported input key: " key)
        }
        next
      }
      if (level == 6 && in_values && raw ~ /^      - /) {
        value = trim(substr(raw, 9))
        if (!is_select_value(value)) fail("SELECT values must be plain word scalars: " value)
        if (seen_select[input_count, value]++) fail("duplicate SELECT value: " value)
        if (input_values[input_count] != "") input_values[input_count] = input_values[input_count] ","
        input_values[input_count] = input_values[input_count] value
        next
      }
      fail("unsupported inputs YAML form")
      next
    }
    section == "tasks" {
      clear_from(level)
      if (raw ~ /^ *- /) {
        if (raw !~ /^ *- id: /) { fail("task list item must begin with id"); next }
        if (owner_kind(level) != "container") {
          fail("task list item is not indented two spaces under a supported tasks, then, or else container")
          next
        }
        task_count++
        value = value_of(raw)
        if (!is_ident(value)) fail("task id must be an unquoted [A-Za-z0-9_-]+ scalar")
        if (seen_task_id[value]++) fail("duplicate task id: " value)
        task_id[task_count] = value
        task_field[task_count, "id"] = 1
        container_items[ctx[level - 2]]++
        ctx[level] = "task" SUBSEP task_count
        next
      }
      if (raw !~ /^ *[A-Za-z][A-Za-z]*:/) { fail("unsupported task YAML form"); next }
      kind = owner_kind(level)
      key = key_of(raw)
      value = value_of(raw)
      if (kind == "retry") {
        task = owner_task(level)
        if (retry_field[task, key]++) fail("duplicate retry key: " key)
        if (key == "type") {
          if (value != "constant") fail("retry type must be constant")
        } else if (key == "interval" || key == "maxDuration") {
          if (value !~ /^PT[0-9]+(\.[0-9]+)?S$/) fail("retry " key " must be a plain second duration")
        } else if (key == "maxAttempts") {
          if (value !~ /^[1-9][0-9]*$/) fail("retry maxAttempts must be a positive integer")
        } else if (key == "warningOnRetry") {
          if (!is_bool(value)) fail("retry warningOnRetry must be true or false")
        } else {
          fail("unsupported retry key: " key)
        }
        next
      }
      if (kind != "task") { fail("unsupported task YAML form"); next }
      task = owner_task(level)
      if (task_field[task, key]++) fail("duplicate task key: " key)
      if (key == "type") {
        if (!(value in ALLOWED)) {
          fail("task type outside the core-plugin allow-list for M1-safe tasks: " value)
        }
        task_type[task] = value
      } else if (key == "tasks" || key == "then" || key == "else") {
        if (value != "") fail("task container " key " must use the supported block-list form")
        ctx[level] = "container" SUBSEP task SUBSEP key
        containers[ctx[level]] = task_id[task] "." key
      } else if (key == "retry") {
        if (value != "") fail("retry must use the supported block-mapping form")
        ctx[level] = "retry" SUBSEP task
      } else if (key == "content") {
        if (value != "|") fail("content is the only supported block scalar and must use |")
        block = level
        block_task = task
      } else if (key == "message" || key == "format" || key == "condition" || key == "errorMessage") {
        if (!is_text(value)) fail("task key " key " must be a double-quoted literal from the supported character set")
      } else if (key == "extension") {
        if (value !~ /^\.[a-z0-9]+$/) fail("extension must be an unquoted .suffix")
      } else {
        fail("unsupported task key: " key)
      }
      next
    }
    END {
      if (flow_id == "") fail("missing top-level id")
      if (flow_ns == "") fail("missing top-level namespace")
      if (!readonly) fail("missing label system.readOnly: \"true\"")
      if (!("tasks" in seen_top)) fail("missing top-level tasks")
      else if (task_count == 0) fail("tasks must declare at least one task")
      for (i = 1; i <= input_count; i++) {
        t = input_type[i]
        if (t == "") { fail("input " input_id[i] " is missing type"); continue }
        if (t != "INT" && (input_field[i, "min"] || input_field[i, "max"])) {
          fail("input " input_id[i] " declares min/max but is not INT")
        }
        if (t == "INT") {
          lo = input_bound[i, "min"]; hi = input_bound[i, "max"]
          if ((lo != "" && (lo + 0 < -2147483648 || lo + 0 > 2147483647)) ||
              (hi != "" && (hi + 0 < -2147483648 || hi + 0 > 2147483647))) {
            fail("input " input_id[i] " has min/max outside the signed 32-bit range")
          } else if (lo != "" && hi != "" && lo + 0 > hi + 0) {
            fail("input " input_id[i] " has min greater than max")
          }
        }
        if (t != "SELECT" && input_field[i, "values"]) fail("input " input_id[i] " declares values but is not SELECT")
        if (t == "SELECT" && input_values[i] == "") fail("SELECT input " input_id[i] " declares no values")
        if (t != "STRING" && input_field[i, "validator"]) fail("input " input_id[i] " declares a validator but is not STRING")
      }
      for (i = 1; i <= task_count; i++) {
        t = task_type[i]
        if (t == "") { fail("task " task_id[i] " is missing type"); continue }
        if (!(t in ALLOWED)) continue
        n = split(ALLOWED[t], required, " ")
        for (j = 1; j <= n; j++) {
          if (!task_field[i, required[j]]) fail("task " task_id[i] " (" t ") is missing " required[j])
        }
        if (t == "io.kestra.plugin.core.storage.Write" && task_field[i, "content"] && !content_lines[i]) {
          fail("task " task_id[i] " has an empty content block")
        }
        if (t == "io.kestra.plugin.core.execution.Fail" && task_field[i, "retry"] &&
            (!retry_field[i, "type"] || !retry_field[i, "interval"] || !retry_field[i, "maxAttempts"] ||
             !retry_field[i, "maxDuration"] || !retry_field[i, "warningOnRetry"])) {
          fail("task " task_id[i] " requires the complete supported retry shape")
        }
      }
      for (pair in task_field) {
        split(pair, parts, SUBSEP)
        if (!field_allowed(task_type[parts[1]], parts[2])) {
          fail("task " task_id[parts[1]] " uses unsupported key for its type: " parts[2])
        }
      }
      for (c in containers) {
        if (!container_items[c]) fail("container " containers[c] " declares no tasks")
      }
      if (problems) exit 1
      print "flow" US flow_id US flow_ns
      for (i = 1; i <= input_count; i++) {
        print "input" US input_id[i] US input_type[i] US input_required[i] US input_bound[i, "min"] US \
          input_bound[i, "max"] US input_values[i] US input_validator[i]
      }
      for (i = 1; i <= task_count; i++) print "task" US task_id[i] US task_type[i]
      exit 0
    }
  ' "$file"
}

# fm_kestra_check_flow <file> [source-name]: validate only. Diagnostics go to
# stderr; returns non-zero on any problem.
fm_kestra_check_flow() {
  fm_kestra_parse_flow "$1" "${2:-$1}" >/dev/null
}

# fm_kestra_flow_records <file>: the validated record stream, or die. Every
# consumer below reads this one stream, so there is exactly one grammar.
fm_kestra_flow_records() {
  local records
  records=$(fm_kestra_parse_flow "$1" "$1") || fm_kestra_die "flow source failed validation: $1"
  printf '%s\n' "$records"
}

fm_kestra_flow_id() {
  fm_kestra_flow_records "$1" | awk -F "$FM_KESTRA_US" '$1 == "flow" { print $2; exit }'
}

fm_kestra_flow_namespace() {
  fm_kestra_flow_records "$1" | awk -F "$FM_KESTRA_US" '$1 == "flow" { print $3; exit }'
}

# fm_kestra_inputs <file>: one record per declared input, US-separated:
#   id | type | required | min | max | values | validator
fm_kestra_inputs() {
  fm_kestra_flow_records "$1" | awk -F "$FM_KESTRA_US" -v OFS="$FM_KESTRA_US" '
    $1 == "input" { print $2, $3, $4, $5, $6, $7, $8 }
  '
}

fm_kestra_task_ids() {
  fm_kestra_flow_records "$1" | awk -F "$FM_KESTRA_US" '$1 == "task" { print $2 }'
}

fm_kestra_task_types() {
  fm_kestra_flow_records "$1" | awk -F "$FM_KESTRA_US" '$1 == "task" { print $3 }'
}

# --- flow identity resolution -----------------------------------------------

# fm_kestra_resolve_flow <flow-id> <out-var> [blob-out-var]: resolve the identity
# against this process's immutable HEAD snapshot and store its snapshot path (and
# blob id) in the named variables.
fm_kestra_resolve_flow() {
  # Locals carry a prefix so a caller may name its output variables freely.
  local fkrf_want=$1 fkrf_out_var=$2 fkrf_blob_var=${3:-} fkrf_index=0 fkrf_file fkrf_match="" fkrf_blob=""
  case "$fkrf_want" in
    ''|*[!a-zA-Z0-9_-]*) fm_kestra_die "flow identity is not allow-listed: ${fkrf_want:-<empty>}" ;;
  esac
  fm_kestra_ensure_flow_snapshot
  for fkrf_file in "${FM_KESTRA_SNAPSHOT_FILES[@]}"; do
    if [ "$(fm_kestra_flow_id "$fkrf_file")" = "$fkrf_want" ]; then
      fkrf_match=$fkrf_file
      fkrf_blob=${FM_KESTRA_SNAPSHOT_BLOBS[$fkrf_index]}
      break
    fi
    fkrf_index=$((fkrf_index + 1))
  done
  [ -n "$fkrf_match" ] || fm_kestra_die "flow identity is not allow-listed: $fkrf_want"
  printf -v "$fkrf_out_var" '%s' "$fkrf_match"
  [ -z "$fkrf_blob_var" ] || printf -v "$fkrf_blob_var" '%s' "$fkrf_blob"
}

fm_kestra_flow_is_in_snapshot() {
  local want=$1 file
  fm_kestra_ensure_flow_snapshot
  for file in "${FM_KESTRA_SNAPSHOT_FILES[@]}"; do
    if [ "$(fm_kestra_flow_id "$file")" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

# --- typed input validation -------------------------------------------------
#
# Every rejection here happens before any HTTP request, so a refused input never
# creates an execution.

fm_kestra_is_integer() {
  [[ $1 =~ ^-?[0-9]+$ ]]
}

fm_kestra_is_int32() {
  fm_kestra_is_integer "$1" || return 1
  [ "$(fm_kestra_compare_integers "$1" -2147483648)" != lt ] \
    && [ "$(fm_kestra_compare_integers "$1" 2147483647)" != gt ]
}

# fm_kestra_compare_integers <left> <right>: print lt, eq, or gt without converting
# either arbitrary-length decimal value to a native shell integer.
fm_kestra_compare_integers() {
  local left=$1 right=$2 left_sign=positive right_sign=positive LC_ALL=C
  case "$left" in -*) left_sign=negative; left=${left#-} ;; esac
  case "$right" in -*) right_sign=negative; right=${right#-} ;; esac
  [[ $left =~ ^0*([0-9]+)$ ]] && left=${BASH_REMATCH[1]}
  [[ $right =~ ^0*([0-9]+)$ ]] && right=${BASH_REMATCH[1]}
  [ "$left" != 0 ] || left_sign=positive
  [ "$right" != 0 ] || right_sign=positive

  if [ "$left_sign" != "$right_sign" ]; then
    [ "$left_sign" = negative ] && printf 'lt\n' || printf 'gt\n'
  elif [ "$left" = "$right" ]; then
    printf 'eq\n'
  elif [ "${#left}" -lt "${#right}" ] \
    || { [ "${#left}" -eq "${#right}" ] && [[ $left < $right ]]; }; then
    [ "$left_sign" = negative ] && printf 'gt\n' || printf 'lt\n'
  else
    [ "$left_sign" = negative ] && printf 'lt\n' || printf 'gt\n'
  fi
}

# fm_kestra_validate_inputs <flow-file> <name=value>...: print the accepted pairs,
# one `name=value` per line, or fail with a diagnostic naming the offending input.
fm_kestra_validate_inputs() {
  local file=$1 record pair name value
  shift
  local schema_ids="" accepted=""

  for pair in "$@"; do
    case "$pair" in
      *=*) : ;;
      *) fm_kestra_die "input must be name=value: $pair" ;;
    esac
    name=${pair%%=*}
    case "$name" in
      ''|*[!a-zA-Z0-9_-]*) fm_kestra_die "input name is not [A-Za-z0-9_-]+: $name" ;;
    esac
  done

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    local in_id in_type in_required in_min in_max in_values in_validator
    IFS=$FM_KESTRA_US read -r in_id in_type in_required in_min in_max in_values in_validator <<< "$record"
    schema_ids="$schema_ids $in_id"

    value=""
    local found=0
    for pair in "$@"; do
      if [ "${pair%%=*}" = "$in_id" ]; then
        value=${pair#*=}
        found=1
      fi
    done

    if [ "$found" -eq 0 ]; then
      # Kestra inputs are required unless the flow says otherwise.
      [ "${in_required:-true}" = "false" ] || fm_kestra_die "missing required input: $in_id"
      continue
    fi

    case "$value" in
      *$'\r'*|*$'\n'*) fm_kestra_die "input $in_id must be a single-line value" ;;
    esac

    case "$in_type" in
      INT)
        fm_kestra_is_integer "$value" \
          || fm_kestra_die "input $in_id must be an integer, got: $value"
        if [ -n "$in_min" ] && [ "$(fm_kestra_compare_integers "$value" "$in_min")" = lt ]; then
          fm_kestra_die "input $in_id must be >= $in_min, got: $value"
        fi
        if [ -n "$in_max" ] && [ "$(fm_kestra_compare_integers "$value" "$in_max")" = gt ]; then
          fm_kestra_die "input $in_id must be <= $in_max, got: $value"
        fi
        fm_kestra_is_int32 "$value" \
          || fm_kestra_die "input $in_id must fit Kestra's signed 32-bit INT range, got: $value"
        ;;
      SELECT)
        local allowed candidate ok=0
        IFS=',' read -r -a allowed <<< "$in_values"
        for candidate in "${allowed[@]}"; do
          [ "$candidate" = "$value" ] && ok=1
        done
        [ "$ok" -eq 1 ] || fm_kestra_die "input $in_id must be one of [$in_values], got: $value"
        ;;
      STRING)
        if [ -n "$in_validator" ]; then
          jq -en --arg value "$value" --arg pattern "$in_validator" '
            $value | test("\\A(" +
              ($pattern | gsub("\\."; "[^\r\n\u0085\u2028\u2029]")) + ")\\z")
          ' >/dev/null \
            || fm_kestra_die "input $in_id must match $in_validator, got: $value"
        fi
        ;;
      *) fm_kestra_die "input $in_id has an input type this adapter cannot pre-check: $in_type" ;;
    esac
    accepted="$accepted$in_id=$value"$'\n'
  done <<< "$(fm_kestra_inputs "$file")"

  # An input the flow does not declare is refused rather than forwarded: forwarding
  # it would hand Kestra a field this adapter never checked.
  for pair in "$@"; do
    name=${pair%%=*}
    case " $schema_ids " in
      *" $name "*) : ;;
      *) fm_kestra_die "input is not declared by this flow: $name" ;;
    esac
  done

  printf '%s' "$accepted"
}

# --- configuration ----------------------------------------------------------
#
# Endpoint and credential live in gitignored local config, never in kestra/ or
# bin/. docs/configuration.md owns where the file lives; docs/examples/kestra-env
# is its copyable shape; no value is committed.

fm_kestra_config_file() {
  printf '%s\n' "${FM_KESTRA_CONFIG:-${FM_CONFIG_OVERRIDE:-$FM_KESTRA_HOME/config}/kestra.env}"
}

fm_kestra_file_mode() {
  local mode
  mode=$(stat -c '%a' "$1" 2>/dev/null) || mode=$(stat -f '%Lp' "$1" 2>/dev/null) || return 1
  printf '%s\n' "$mode"
}

# fm_kestra_load_config: populate FM_KESTRA_BASE_URL, FM_KESTRA_TENANT,
# FM_KESTRA_NAMESPACE, and the credential, then enforce the loopback rule.
# Environment values win over the file so a caller can drive a test endpoint
# without writing config; both paths land in the same validation.
fm_kestra_load_config() {
  local file line key value mode
  file=$(fm_kestra_config_file)
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] \
      || fm_kestra_die "Kestra config must be a regular, non-symlink file: $file"
    mode=$(fm_kestra_file_mode "$file") \
      || fm_kestra_die "could not verify Kestra config permissions: $file"
    [ "$mode" = 600 ] \
      || fm_kestra_die "Kestra config must have mode 0600: $file"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|'#'*) continue ;;
        *=*) : ;;
        *) continue ;;
      esac
      key=${line%%=*}
      value=${line#*=}
      key=${key# }
      key=${key%% *}
      value=${value%\"}
      value=${value#\"}
      case "$key" in
        FM_KESTRA_BASE_URL|FM_KESTRA_TENANT|FM_KESTRA_NAMESPACE|FM_KESTRA_USER|FM_KESTRA_PASSWORD)
          # Environment wins, so only fill what the caller did not set.
          if [ -z "${!key:-}" ]; then
            printf -v "$key" '%s' "$value"
          fi
          ;;
      esac
    done < "$file"
  fi

  FM_KESTRA_TENANT=${FM_KESTRA_TENANT:-main}
  : "${FM_KESTRA_BASE_URL:=}" "${FM_KESTRA_NAMESPACE:=}"
  : "${FM_KESTRA_USER:=}" "${FM_KESTRA_PASSWORD:=}"
  export -n FM_KESTRA_USER FM_KESTRA_PASSWORD

  [ -n "$FM_KESTRA_BASE_URL" ] \
    || fm_kestra_die "FM_KESTRA_BASE_URL is not configured (see $file)"
  [ -n "$FM_KESTRA_NAMESPACE" ] \
    || fm_kestra_die "FM_KESTRA_NAMESPACE is not configured (see $file)"
  case "$FM_KESTRA_TENANT" in
    ''|*[!a-zA-Z0-9_-]*) fm_kestra_die "FM_KESTRA_TENANT is not [A-Za-z0-9_-]+" ;;
  esac
  case "$FM_KESTRA_NAMESPACE" in
    *[!a-zA-Z0-9._-]*) fm_kestra_die "FM_KESTRA_NAMESPACE is not [A-Za-z0-9._-]+" ;;
  esac
  # curl's config-file syntax quotes the credential, so a value containing a
  # double quote, a backslash, or a newline would change the file's meaning. Refuse
  # it without echoing the value.
  local backslash
  backslash=$(printf '\134')
  case "$FM_KESTRA_USER$FM_KESTRA_PASSWORD" in
    *'"'*|*"$backslash"*) fm_kestra_die "credential must not contain a double quote or backslash" ;;
  esac
  case "$FM_KESTRA_USER$FM_KESTRA_PASSWORD" in
    *'
'*) fm_kestra_die "credential must not contain a newline" ;;
  esac
  fm_kestra_assert_loopback "$FM_KESTRA_BASE_URL"
}

# fm_kestra_assert_loopback <url>: refuse anything but a loopback http(s) endpoint.
# M1 binds Kestra's main and management servers to loopback, so a non-loopback URL
# means the seam is pointed at something it was never authorized to reach.
fm_kestra_assert_loopback() {
  local url=$1 rest hostport host port
  case "$url" in
    http://*) rest=${url#http://} ;;
    https://*) rest=${url#https://} ;;
    *) fm_kestra_die "endpoint must be http:// or https://: $url" ;;
  esac
  case "$rest" in
    *@*) fm_kestra_die "endpoint must not embed credentials" ;;
    *'?'*|*'#'*) fm_kestra_die "endpoint must not contain a query or fragment" ;;
  esac
  hostport=${rest%%/*}
  host=${hostport%%:*}
  case "$hostport" in
    '['*) host=${hostport%%]*}; host=${host#[} ;;
  esac
  case "$host" in
    127.0.0.1|localhost|::1) : ;;
    *) fm_kestra_die "endpoint must be loopback (127.0.0.1, localhost, or [::1]): $host" ;;
  esac
  local endpoint_re='^https?://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*/?$'
  [[ "$url" =~ $endpoint_re ]] || fm_kestra_die "endpoint has unsupported URL syntax"
  port=${BASH_REMATCH[2]#:}
  if [ -n "$port" ]; then
    [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] \
      || fm_kestra_die "endpoint port must be between 1 and 65535"
  fi
  case "$rest/" in
    */./*|*/../*) fm_kestra_die "endpoint must not contain dot path segments" ;;
  esac
}

# --- the deployed-revision record -------------------------------------------
#
# data/kestra/revisions in the operating home records, one line per flow, the
# Kestra revision that fm-kestra-deploy.sh verified to carry the reviewed HEAD
# bytes:
#   <flow-id> TAB <namespace> TAB <revision> TAB <git blob id> TAB <HEAD commit>
# The blob id is the content identity: a run refuses when the current HEAD blob
# differs from the recorded one, because the reviewed flow has changed since it was
# deployed and the record no longer describes what would run. The file is replaced
# atomically and describes exactly the set of flows the last deployment covered.

fm_kestra_revision_record_file() {
  printf '%s\n' "$FM_KESTRA_HOME/data/kestra/revisions"
}

# fm_kestra_write_revision_record <lines...>: replace the record with the given
# already-formatted lines.
fm_kestra_write_revision_record() {
  local file dir staging line
  file=$(fm_kestra_revision_record_file)
  dir=$(dirname -- "$file")
  mkdir -p -- "$dir" || fm_kestra_die "could not create the revision record directory: $dir" 1
  fm_kestra_tempfile revisions staging "$dir" \
    || fm_kestra_die "could not stage the revision record" 1
  for line in "$@"; do
    printf '%s\n' "$line" >> "$staging"
  done
  mv -- "$staging" "$file" || fm_kestra_die "could not replace the revision record: $file" 1
}

# fm_kestra_recorded_revision <flow-id> <namespace> <revision-out-var> <blob-out-var>:
# look the flow up in the record, or die with the reason the run cannot be bound.
fm_kestra_recorded_revision() {
  # Locals carry a prefix so a caller may name its output variables freely.
  local fkrr_want=$1 fkrr_ns=$2 fkrr_revision_var=$3 fkrr_blob_var=$4
  local fkrr_file fkrr_flow fkrr_rec_ns fkrr_revision fkrr_blob fkrr_head fkrr_found=0
  fkrr_file=$(fm_kestra_revision_record_file)
  [ -f "$fkrr_file" ] \
    || fm_kestra_die "flow $fkrr_want has no recorded deployed revision (run bin/fm-kestra-deploy.sh first; record: $fkrr_file)"
  while IFS=$'\t' read -r fkrr_flow fkrr_rec_ns fkrr_revision fkrr_blob fkrr_head; do
    [ -n "$fkrr_flow" ] || continue
    [ "$fkrr_flow" = "$fkrr_want" ] && [ "$fkrr_rec_ns" = "$fkrr_ns" ] || continue
    case "$fkrr_revision" in ''|*[!0-9]*|0*) fm_kestra_die "revision record for $fkrr_want is malformed: $fkrr_file" ;; esac
    case "$fkrr_blob" in ''|*[!0-9a-f]*) fm_kestra_die "revision record for $fkrr_want is malformed: $fkrr_file" ;; esac
    case "$fkrr_head" in ''|*[!0-9a-f]*) fm_kestra_die "revision record for $fkrr_want is malformed: $fkrr_file" ;; esac
    fkrr_found=1
    break
  done < "$fkrr_file"
  [ "$fkrr_found" -eq 1 ] \
    || fm_kestra_die "flow $fkrr_want has no recorded deployed revision in $fkrr_ns (run bin/fm-kestra-deploy.sh first)"
  printf -v "$fkrr_revision_var" '%s' "$fkrr_revision"
  printf -v "$fkrr_blob_var" '%s' "$fkrr_blob"
}

# fm_kestra_normalize_source: stdin to stdout, with leading/trailing empty lines
# dropped and all whitespace within source lines preserved.
fm_kestra_normalize_source() {
  awk '
    { lines[NR] = $0; if ($0 != "") { last = NR; if (!first) first = NR } }
    END { for (i = first; i <= last; i++) print lines[i] }
  '
}

# fm_kestra_verify_revision_source <flow-id> <namespace> <revision> <snapshot-file>:
# read the flow at that exact revision from Kestra and require its source to be the
# reviewed HEAD bytes. Exit 1 on a transport or server failure, 2 on a mismatch.
fm_kestra_verify_revision_source() {
  local flow=$1 ns=$2 revision=$3 snapshot=$4 rc=0 response returned server_source expected
  response=$(fm_kestra_request read GET "/flows/$ns/$flow?revision=$revision&source=true") || rc=$?
  if [ "$rc" -eq 2 ]; then
    exit 2
  elif [ "$rc" -ne 0 ]; then
    [ -z "$response" ] || printf '%s\n' "$response" >&2
    fm_kestra_die "could not read revision $revision of flow $ns/$flow" 1
  fi
  returned=$(printf '%s' "$response" | jq -r --arg id "$flow" --arg ns "$ns" '
    select(type == "object" and .id == $id and .namespace == $ns) |
    .revision | select(type == "number" and . >= 1 and floor == .) | tostring
  ' 2>/dev/null) || returned=""
  [ "$returned" = "$revision" ] \
    || fm_kestra_die "refused: Kestra did not return revision $revision of flow $ns/$flow"
  server_source=$(printf '%s' "$response" | jq -r '.source | select(type == "string")' 2>/dev/null \
    | fm_kestra_normalize_source) || server_source=""
  expected=$(fm_kestra_normalize_source < "$snapshot")
  [ -n "$server_source" ] && [ "$server_source" = "$expected" ] \
    || fm_kestra_die "refused: revision $revision of flow $ns/$flow does not carry the reviewed source; redeploy before running"
}

# --- private temporary files ------------------------------------------------
#
# One owner per shell process, so parent staging files and subshell request
# credentials cannot replace or inherit each other's cleanup registration.

FM_KESTRA_TEMPFILES=()
FM_KESTRA_TEMPFILE_PID=""

fm_kestra_tempfile_cleanup() {
  local file
  for file in "${FM_KESTRA_TEMPFILES[@]}"; do
    [ -n "$file" ] && rm -f -- "$file"
  done
}

fm_kestra_tempfile_register_cleanup() {
  local pid="$$:${BASH_SUBSHELL:-0}"
  if [ "$FM_KESTRA_TEMPFILE_PID" != "$pid" ]; then
    FM_KESTRA_TEMPFILES=()
    FM_KESTRA_TEMPFILE_PID=$pid
    trap fm_kestra_tempfile_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
}

# fm_kestra_tempfile <label> <out-var> [directory]: create a fresh mode-0600 temp
# file and store its path in <out-var>, registered for removal when the calling
# script exits or is interrupted.
#
# The path is returned through a variable rather than stdout on purpose. A
# `$(...)` capture runs in a subshell, and the EXIT trap this registers would fire
# the moment that subshell ended, deleting the file before the caller could use it.
fm_kestra_tempfile() {
  local file old_umask dir
  fm_kestra_tempfile_register_cleanup
  dir=${3:-${TMPDIR:-/tmp}}
  old_umask=$(umask)
  umask 077
  file=$(mktemp "$dir/.fm-kestra-$1.XXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  chmod 0600 "$file" 2>/dev/null || true
  FM_KESTRA_TEMPFILES+=("$file")
  printf -v "$2" '%s' "$file"
}

# --- the HTTP gate ----------------------------------------------------------
#
# fm_kestra_request is the ONLY place this seam speaks HTTP. Each role positively
# allows a small set of (method, path) shapes and refuses everything else, so
# replay, restart, resume, kill, state override, flow deletion, secret access, and
# namespace administration are denied structurally rather than left undocumented.

fm_kestra_path_has_forbidden_segment() {
  local path=${1%%\?*} segment
  local segments=()
  IFS='/' read -r -a segments <<< "$path"
  for segment in "${segments[@]}"; do
    case "$segment" in
      replay|restart|resume|kill|state|set-labels|change-status|secrets|namespaces|users|bindings|apitokens)
        return 0
        ;;
    esac
  done
  return 1
}

# fm_kestra_path_allowed <role> <method> <path>: 0 when the role allows it.
fm_kestra_path_allowed() {
  local role=$1 method=$2 path=$3

  # Belt and braces: no role may ever reach a state-changing or secret surface,
  # whatever its own pattern list says.
  fm_kestra_path_has_forbidden_segment "$path" && return 1
  case "$method" in
    DELETE|PUT|PATCH) return 1 ;;
  esac

  local ns=${FM_KESTRA_NAMESPACE:-} tail flow revision
  case "$role" in
    deploy)
      # Exact matches, not prefixes: no extra query parameter is allowed.
      case "$method $path" in
        'POST /flows/validate') return 0 ;;
        "POST /flows/$ns?delete=false") [ -n "$ns" ] && return 0 ;;
      esac
      ;;
    run)
      # One flow inside the one allow-listed namespace, bound to one explicit
      # revision. A path without `?revision=` is refused, so a run can never fall
      # through to whatever revision the server currently considers latest.
      case "$method $path" in
        "POST /executions/$ns/"*)
          [ -n "$ns" ] || return 1
          tail=${path#"/executions/$ns/"}
          flow=${tail%%\?*}
          [ "$flow" != "$tail" ] || return 1
          case "$flow" in ''|*/*|*[!a-zA-Z0-9_-]*) return 1 ;; esac
          revision=${tail#*\?}
          case "$revision" in revision=*) revision=${revision#revision=} ;; *) return 1 ;; esac
          case "$revision" in ''|*[!0-9]*|0*) return 1 ;; esac
          fm_kestra_flow_is_in_snapshot "$flow" && return 0
          ;;
      esac
      ;;
    read)
      case "$method $path" in
        'GET /executions/'*)
          tail=${path#/executions/}
          case "$tail" in
            ''|*'?'*|*/*|*[!a-zA-Z0-9_-]*) : ;;
            *) return 0 ;;
          esac
          case "$tail" in
            */file\?path=*)
              local execution=${tail%%/*} encoded=${tail#*/file?path=}
              case "$execution" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
              case "$encoded" in ''|*[!a-zA-Z0-9%._~-]*) return 1 ;; esac
              return 0
              ;;
          esac
          ;;
        'GET /logs/'*)
          tail=${path#/logs/}
          case "$tail" in ''|*'?'*|*/*|*[!a-zA-Z0-9_-]*) : ;; *) return 0 ;; esac
          ;;
        "GET /flows/$ns/"*)
          [ -n "$ns" ] || return 1
          tail=${path#"/flows/$ns/"}
          case "$tail" in
            *'?revision='*'&source=true')
              flow=${tail%%\?*}
              revision=${tail#*'?revision='}
              revision=${revision%&source=true}
              case "$flow" in ''|*/*|*[!a-zA-Z0-9_-]*) return 1 ;; esac
              case "$revision" in ''|*[!0-9]*|0*) return 1 ;; esac
              return 0
              ;;
          esac
          ;;
      esac
      ;;
  esac
  return 1
}

fm_kestra_curl_request() {
  local role=$1 method=$2 path=$3 output=$4 netrc="" rc url target prefix
  shift 4
  fm_kestra_assert_loopback "$FM_KESTRA_BASE_URL"
  case "$FM_KESTRA_TENANT" in
    ''|*[!a-zA-Z0-9_-]*) fm_kestra_die "FM_KESTRA_TENANT is not [A-Za-z0-9_-]+" ;;
  esac
  url="${FM_KESTRA_BASE_URL%/}/api/v1/$FM_KESTRA_TENANT$path"
  local request_re='^https?://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+(\?[A-Za-z0-9%._~=&-]+)?$'
  [[ "$url" =~ $request_re ]] || fm_kestra_die "refused: unsupported request URL syntax"
  target=${url#*://}
  target=/${target#*/}
  case "${target%%\?*}/" in
    */./*|*/../*) fm_kestra_die "refused: request URL contains dot path segments" ;;
  esac
  prefix=${FM_KESTRA_BASE_URL%/}
  prefix=${prefix#*://}
  case "$prefix" in */*) prefix=/${prefix#*/} ;; *) prefix="" ;; esac
  target=${target#"$prefix/api/v1/$FM_KESTRA_TENANT"}
  fm_kestra_path_allowed "$role" "$method" "$target" \
    || fm_kestra_die "refused: $role may not $method $target"
  local curl_args=()
  fm_kestra_tempfile auth netrc || return 1
  printf 'user = "%s:%s"\n' "$FM_KESTRA_USER" "$FM_KESTRA_PASSWORD" > "$netrc" || {
    rm -f -- "$netrc"
    return 1
  }
  curl_args=(-q --noproxy '*' --config "$netrc" --fail-with-body -sS \
    --max-time "${FM_KESTRA_TIMEOUT_S:-30}")
  curl_args+=("$@")
  if [ -n "$output" ]; then
    curl_args+=(--output "$output")
  fi
  curl_args+=(--request "$method" "$url")
  curl "${curl_args[@]}"
  rc=$?
  rm -f -- "$netrc"
  return "$rc"
}

fm_kestra_request_to_file() {
  local path=$1 output=$2
  command -v curl >/dev/null 2>&1 || fm_kestra_die "curl is required for the Kestra seam" 1
  fm_kestra_path_allowed read GET "$path" \
    || fm_kestra_die "refused: read may not GET $path"
  [ -f "$output" ] && [ ! -L "$output" ] \
    || fm_kestra_die "refused: read output is not a regular staging file"
  fm_kestra_curl_request read GET "$path" "$output"
}

# The deploy files are staged once per process from the HEAD snapshot, inside the
# gate, so validation and deployment upload the same files as separate form parts.
FM_KESTRA_DEPLOY_FILES=()

fm_kestra_stage_deploy_files() {
  local file
  if [ "${#FM_KESTRA_DEPLOY_FILES[@]}" -gt 0 ]; then
    return 0
  fi
  fm_kestra_ensure_flow_snapshot
  [ "${#FM_KESTRA_SNAPSHOT_FILES[@]}" -gt 0 ] \
    || fm_kestra_die "refused: no tracked flows to deploy"
  fm_kestra_assert_flows_unchanged "$FM_KESTRA_SNAPSHOT_HEAD"
  for file in "${FM_KESTRA_SNAPSHOT_FILES[@]}"; do
    fm_kestra_check_flow "$file" >/dev/null 2>&1 \
      || fm_kestra_die "refused: a snapshot flow failed validation and cannot be deployed"
  done
  FM_KESTRA_DEPLOY_FILES=("${FM_KESTRA_SNAPSHOT_FILES[@]}")
}

# fm_kestra_request <role> <method> <path> [structured payload...]
#
# Writes the response body to stdout and returns curl's status. The credential is
# supplied through a mode-0600 config file removed on exit, never through argv.
# Deploy takes no payload and uploads the staged HEAD snapshot files, run accepts
# only literal name=value form fields, and read accepts no payload.
fm_kestra_request() {
  local role=$1 method=$2 path=$3
  shift 3
  command -v curl >/dev/null 2>&1 || fm_kestra_die "curl is required for the Kestra seam" 1

  fm_kestra_path_allowed "$role" "$method" "$path" \
    || fm_kestra_die "refused: $role may not $method $path"

  local field name
  local request_args=()
  case "$role" in
    deploy)
      [ "$#" -eq 0 ] || fm_kestra_die "refused: deploy requests take no payload; the HEAD snapshot is the body"
      fm_kestra_stage_deploy_files
      local file index=0
      for file in "${FM_KESTRA_DEPLOY_FILES[@]}"; do
        file=${file//\\/\\\\}
        file=${file//\"/\\\"}
        request_args+=(--form "flows=@\"$file\";filename=flow-$index.yaml;type=application/x-yaml")
        index=$((index + 1))
      done
      ;;
    run)
      for field in "$@"; do
        case "$field" in
          *=*) : ;;
          *) fm_kestra_die "refused: run request field must be name=value" ;;
        esac
        name=${field%%=*}
        case "$name" in
          ''|-*|*[!a-zA-Z0-9_-]*) fm_kestra_die "refused: run request field has an invalid name" ;;
        esac
        case "$field" in
          *$'\r'*|*$'\n'*) fm_kestra_die "refused: run request field must be single-line" ;;
        esac
        request_args+=(--form-string "$field")
      done
      ;;
    read)
      [ "$#" -eq 0 ] || fm_kestra_die "refused: read requests do not accept a payload"
      ;;
    *) fm_kestra_die "refused: unknown Kestra request role: $role" ;;
  esac

  fm_kestra_curl_request "$role" "$method" "$path" "" ${request_args+"${request_args[@]}"}
}
