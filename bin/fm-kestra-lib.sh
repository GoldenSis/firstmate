#!/usr/bin/env bash
# fm-kestra-lib.sh - shared, fail-closed helpers for firstmate's Kestra execution seam.
#
# This library is the single owner of four contracts the three seam entrypoints
# (fm-kestra-deploy.sh, fm-kestra-run.sh, fm-kestra-status.sh) all depend on:
#
#   1. Local configuration and the loopback-only endpoint rule.
#   2. Flow-identity resolution against one immutable snapshot of the tracked,
#      unchanged HEAD blobs under kestra/flows/. A flow that is not in that snapshot
#      is not addressable, and a local flow edit stops the seam.
#   3. Static flow-source validation against the exact YAML shape, task types, and
#      input schema M1 supports. Unsupported syntax, triggers, and side-effecting
#      task types are refused rather than approximated.
#   4. The HTTP gate. Every request goes through fm_kestra_request, which takes a
#      ROLE and refuses any method/path the role does not positively allow. Replay,
#      restart, resume, kill, state override, flow deletion, secrets, and namespace
#      administration are unreachable from every role, so a coding mistake in a
#      caller cannot reach them either.
#
# Authority stays outside Kestra. Nothing here lets a flow result approve, merge,
# route, or unlock anything: a Kestra state is evidence that a task ran and nothing
# more.
#
# Version pin. This seam targets Kestra Open Source Edition 1.3.34 and the official
# standalone asset
#   https://github.com/kestra-io/kestra/releases/download/v1.3.34/kestra-1.3.34
# whose publisher-listed SHA-256 is
#   de846ac42e2b35a2e55301d01335de6ea30eab77fd69570f238e06ea28149a4b
# fm_kestra_pinned_version and fm_kestra_pinned_sha256 below are the single source
# of those values; docs/kestra-seam.md explains how to verify them. No `latest`
# tag and no unversioned image is supported.
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

# --- tracked flow directory -------------------------------------------------

# The flow source directory is always resolved from the CODE root, never from
# FM_HOME: flows are shared tracked material that Git reviews, not per-home local
# state that an operator can vary.
fm_kestra_flows_dir() {
  printf '%s\n' "$FM_KESTRA_ROOT/kestra/flows"
}

# fm_kestra_flow_files: print every tracked flow file, sorted, one per line.
fm_kestra_flow_files() {
  local dir relative untracked
  dir=$(fm_kestra_flows_dir)
  [ -d "$dir" ] || fm_kestra_die "flow directory is unavailable: $dir"
  git -C "$FM_KESTRA_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 \
    || fm_kestra_die "flow allow-list is unavailable from Git HEAD"
  git -C "$FM_KESTRA_ROOT" diff --quiet HEAD -- kestra/flows \
    || fm_kestra_die "tracked flow sources have local changes; commit them before using the seam"
  untracked=$(git -C "$FM_KESTRA_ROOT" ls-files --others --exclude-standard -- 'kestra/flows/*.yaml')
  [ -z "$untracked" ] \
    || fm_kestra_die "untracked flow sources are present; commit or remove them before using the seam"
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$relative" in
      kestra/flows/*.yaml) : ;;
      *) fm_kestra_die "tracked flow path is outside kestra/flows: $relative" ;;
    esac
    case "${relative#kestra/flows/}" in
      */*) fm_kestra_die "tracked flow source must be directly under kestra/flows: $relative" ;;
    esac
    [ ! -L "$FM_KESTRA_ROOT/$relative" ] && [ -f "$FM_KESTRA_ROOT/$relative" ] \
      || fm_kestra_die "tracked flow source is not a regular file: $relative"
    printf '%s\n' "$FM_KESTRA_ROOT/$relative"
  done < <(git -C "$FM_KESTRA_ROOT" ls-files -- 'kestra/flows/*.yaml' | LC_ALL=C sort)
}

FM_KESTRA_SNAPSHOT_FILES=()
FM_KESTRA_SNAPSHOT_SOURCES=()
FM_KESTRA_SNAPSHOT_HEAD=""

# fm_kestra_snapshot_flow_files: populate parallel arrays with immutable copies of
# the current HEAD flow blobs and their canonical source paths.
fm_kestra_snapshot_flow_files() {
  local head relative metadata mode type object snapshot untracked current_head
  FM_KESTRA_SNAPSHOT_FILES=()
  FM_KESTRA_SNAPSHOT_SOURCES=()
  FM_KESTRA_SNAPSHOT_HEAD=""
  head=$(git -C "$FM_KESTRA_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || fm_kestra_die "flow allow-list is unavailable from Git HEAD"
  git -C "$FM_KESTRA_ROOT" diff --quiet "$head" -- kestra/flows \
    || fm_kestra_die "tracked flow sources have local changes; commit them before using the seam"
  untracked=$(git -C "$FM_KESTRA_ROOT" ls-files --others --exclude-standard -- 'kestra/flows/*.yaml')
  [ -z "$untracked" ] \
    || fm_kestra_die "untracked flow sources are present; commit or remove them before using the seam"

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
  done < <(git -C "$FM_KESTRA_ROOT" ls-tree -r "$head" -- kestra/flows | LC_ALL=C sort -k2)

  git -C "$FM_KESTRA_ROOT" diff --quiet "$head" -- kestra/flows \
    || fm_kestra_die "tracked flow sources changed while their HEAD snapshot was being prepared"
  untracked=$(git -C "$FM_KESTRA_ROOT" ls-files --others --exclude-standard -- 'kestra/flows/*.yaml')
  [ -z "$untracked" ] \
    || fm_kestra_die "untracked flow sources appeared while the HEAD snapshot was being prepared"
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

# --- flow source parsing ----------------------------------------------------
#
# The parser understands exactly the YAML subset the tracked flows are allowed to
# use, and fm_kestra_check_flow rejects anything outside it. That is deliberate:
# an adapter that silently skipped a construct it did not understand would under-
# validate inputs and call it a pass.

# fm_kestra_scalar <file> <key>: print the value of a top-level `key: value` line.
fm_kestra_scalar() {
  local file=$1 key=$2
  awk -v key="$key" '
    index($0, key ":") == 1 {
      value = substr($0, length(key) + 2)
      sub(/^[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
      exit
    }
  ' "$file"
}

fm_kestra_supported_yaml() {
  local file=$1 source=${2:-$1}
  awk -v source="$source" '
    BEGIN { section = ""; block_indent = -1; problems = 0 }
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
    function mapping_key(line, value) {
      value = line
      sub(/^[ ]*-?[ ]*/, "", value)
      sub(/:.*/, "", value)
      return value
    }
    function mapping_value(line, value) {
      value = line
      sub(/^[^:]*:[ \t]*/, "", value)
      return trim(value)
    }
    function clear_from(level, i) {
      for (i in tasks) if ((i + 0) >= level) delete tasks[i]
      for (i in containers) if ((i + 0) >= level) delete containers[i]
      for (i in retries) if ((i + 0) >= level) delete retries[i]
    }
    function plain_identity(value) {
      return value ~ /^[A-Za-z0-9_-]+$/
    }
    function plain_namespace(value) {
      return value ~ /^[A-Za-z0-9._-]+$/
    }
    function plain_select(value) {
      return value ~ /^[A-Za-z0-9._ -]+$/ && value !~ /  / && value !~ /^ | $/
    }
    function task_field_allowed(type, key) {
      if (key == "id" || key == "type") return 1
      if (type == "io.kestra.plugin.core.log.Log") return key == "message"
      if (type == "io.kestra.plugin.core.debug.Return") return key == "format"
      if (type == "io.kestra.plugin.core.flow.Sequential" ||
          type == "io.kestra.plugin.core.flow.Parallel") return key == "tasks"
      if (type == "io.kestra.plugin.core.flow.If") {
        return key == "condition" || key == "then" || key == "else"
      }
      if (type == "io.kestra.plugin.core.storage.Write") {
        return key == "extension" || key == "content"
      }
      if (type == "io.kestra.plugin.core.execution.Fail") {
        return key == "errorMessage" || key == "retry"
      }
      return 0
    }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    {
      raw = $0
      if (raw ~ /\t/) {
        fail("tabs are not supported in flow YAML")
        next
      }
      level = indent(raw)
      if (block_indent >= 0) {
        if (level > block_indent) next
        block_indent = -1
      }
      if (level % 2 != 0) fail("indentation must use two-space levels")
      if (raw ~ /(^|[ :])<<:/ || raw ~ /(^|[ :\-])[&*][A-Za-z0-9_-]+/) {
        fail("YAML anchors, aliases, and merge keys are not supported")
      }
      if (raw ~ /:[ ]*[\[{]/) fail("flow-style mappings and sequences are not supported")
      if (raw ~ /^[ ]*(---|\.\.\.)[ ]*$/ || raw ~ /^[ ]*%/) {
        fail("YAML directives and document markers are not supported inside a flow")
      }
    }
    level == 0 {
      clear_from(0)
      if (raw !~ /^[A-Za-z_][A-Za-z0-9_.-]*:/) {
        fail("unsupported top-level YAML form")
        section = ""
        next
      }
      key = mapping_key(raw)
      value = mapping_value(raw)
      if (seen_top[key]++) fail("duplicate top-level key: " key)
      if (key == "triggers") {
        fail("top-level triggers are refused because executions must start through the run adapter")
        section = ""
      } else if (key == "id") {
        section = ""
        if (!plain_identity(value)) fail("top-level id must be an unquoted [A-Za-z0-9_-]+ scalar")
      } else if (key == "namespace") {
        section = ""
        if (!plain_namespace(value)) fail("top-level namespace must be an unquoted [A-Za-z0-9._-]+ scalar")
      } else if (key == "labels" || key == "inputs" || key == "tasks" || key == "outputs") {
        section = key
        if (value != "") fail("top-level " key " must use the supported block form")
        if (key == "tasks") containers[0] = "tasks"
      } else {
        fail("unsupported top-level key: " key)
        section = ""
      }
      next
    }
    section == "labels" {
      if (level != 2 || raw !~ /^  system\.readOnly:[ ]*("true"|true)[ ]*$/) {
        fail("labels must contain only system.readOnly: \"true\"")
      }
      next
    }
    section == "inputs" {
      if (level == 2 && raw ~ /^  - id:/) {
        input_count++
        input_id = mapping_value(raw)
        values_input = 0
        if (!plain_identity(input_id)) fail("input id must be an unquoted [A-Za-z0-9_-]+ scalar")
        if (seen_input_id[input_id]++) fail("duplicate input id: " input_id)
        input_ids[input_count] = input_id
        next
      }
      if (level == 4 && input_count > 0 && raw ~ /^    [A-Za-z_][A-Za-z0-9_]*:/) {
        key = mapping_key(raw)
        value = mapping_value(raw)
        values_input = 0
        if (input_fields[input_count, key]++) fail("duplicate input key: " key)
        if (key == "type") {
          if (value !~ /^(INT|SELECT|STRING)$/) fail("unsupported input type: " value)
          input_types[input_count] = value
        } else if (key == "required") {
          if (value !~ /^(true|false)$/) fail("input required must be true or false")
        } else if (key == "min" || key == "max") {
          if (value !~ /^-?[0-9]+$/) fail("input " key " must be an unquoted integer")
        } else if (key == "validator") {
          if (value == "" || substr(value, 1, 1) == "\"" ||
              substr(value, 1, 1) == sprintf("%c", 39)) {
            fail("input validator must be a non-empty unquoted scalar")
          }
        } else if (key == "defaults") {
          if (value == "" || substr(value, 1, 1) == "\"" ||
              substr(value, 1, 1) == sprintf("%c", 39)) {
            fail("input defaults must be a non-empty unquoted scalar")
          }
        } else if (key == "description") {
          if (value == "" || value ~ /^[|>]/) fail("input description must be a single-line scalar")
        } else if (key == "values") {
          if (value != "") fail("SELECT values must use the supported block-list form")
          values_input = input_count
        } else {
          fail("unsupported input key: " key)
        }
        next
      }
      if (level == 6 && values_input == input_count && raw ~ /^      - /) {
        value = raw
        sub(/^      - /, "", value)
        value = trim(value)
        if (!plain_select(value) || value ~ /[,#]/) fail("SELECT values must be exact unquoted scalars")
        if (seen_select[input_count, value]++) fail("duplicate SELECT value: " value)
        select_count[input_count]++
        next
      }
      fail("unsupported inputs YAML form")
      next
    }
    section == "tasks" {
      clear_from(level)
      if (raw ~ /^[ ]*- id:/) {
        if (!(level - 2 in containers)) {
          fail("task list item is outside a supported tasks, then, or else container")
          next
        }
        task_count++
        task_id = mapping_value(raw)
        if (!plain_identity(task_id)) fail("task id must be an unquoted [A-Za-z0-9_-]+ scalar")
        if (seen_task_id[task_id]++) fail("duplicate task id: " task_id)
        tasks[level] = task_count
        task_ids[task_count] = task_id
        task_fields[task_count, "id"] = 1
        next
      }
      if (level - 2 in retries) {
        key = mapping_key(raw)
        value = mapping_value(raw)
        task = retries[level - 2]
        if (retry_fields[task, key]++) fail("duplicate retry key: " key)
        if (key == "type") {
          if (value != "constant") fail("retry type must be constant")
        } else if (key == "interval" || key == "maxDuration") {
          if (value !~ /^PT[0-9]+([.][0-9]+)?S$/) fail("retry " key " must be a plain second duration")
        } else if (key == "maxAttempts") {
          if (value !~ /^[1-9][0-9]*$/) fail("retry maxAttempts must be a positive integer")
        } else if (key == "warningOnRetry") {
          if (value !~ /^(true|false)$/) fail("retry warningOnRetry must be true or false")
        } else {
          fail("unsupported retry key: " key)
        }
        next
      }
      if (!(level - 2 in tasks) || raw !~ /^[ ]*[A-Za-z_][A-Za-z0-9_]*:/) {
        fail("unsupported task YAML form")
        next
      }
      task = tasks[level - 2]
      key = mapping_key(raw)
      value = mapping_value(raw)
      if (task_fields[task, key]++) fail("duplicate task key: " key)
      if (key == "type") {
        if (value !~ /^io[.]kestra[.]plugin[.]core[.][A-Za-z0-9_.]+$/) {
          fail("task type must be an unquoted core-plugin identity")
        }
        task_types[task] = value
      } else if (key == "tasks" || key == "then" || key == "else") {
        if (value != "") fail("task container " key " must use the supported block-list form")
        containers[level] = key
      } else if (key == "retry") {
        if (value != "") fail("retry must use the supported block-mapping form")
        retries[level] = task
      } else if (key == "content") {
        if (value != "|") fail("content is the only supported block scalar and must use |")
        block_indent = level
      } else if (key == "message" || key == "format" || key == "condition" ||
                 key == "extension" || key == "errorMessage") {
        if (value == "" || value ~ /^[|>]/) fail("task key " key " must be a single-line scalar")
      } else {
        fail("unsupported task key: " key)
      }
      next
    }
    section == "outputs" {
      if (level == 2 && raw ~ /^  - id:/) {
        output_count++
        output_id = mapping_value(raw)
        if (!plain_identity(output_id)) fail("output id must be an unquoted [A-Za-z0-9_-]+ scalar")
        if (seen_output_id[output_id]++) fail("duplicate output id: " output_id)
        next
      }
      if (level == 4 && output_count > 0 && raw ~ /^    [A-Za-z_][A-Za-z0-9_]*:/) {
        key = mapping_key(raw)
        value = mapping_value(raw)
        if (output_fields[output_count, key]++) fail("duplicate output key: " key)
        if (key == "type") {
          if (value !~ /^(FILE|STRING)$/) fail("unsupported output type: " value)
          output_types[output_count] = value
        } else if (key == "value") {
          if (value == "" || value ~ /^[|>]/) fail("output value must be a single-line scalar")
          output_values[output_count] = value
        } else {
          fail("unsupported output key: " key)
        }
        next
      }
      fail("unsupported outputs YAML form")
      next
    }
    {
      fail("content outside a supported top-level section")
    }
    END {
      if (!("id" in seen_top)) fail("missing top-level id")
      if (!("namespace" in seen_top)) fail("missing top-level namespace")
      if (!("labels" in seen_top)) fail("missing top-level labels")
      if (!("tasks" in seen_top)) fail("missing top-level tasks")
      if (task_count == 0) fail("tasks must declare at least one task")
      for (i = 1; i <= input_count; i++) {
        if (input_types[i] == "") fail("input " input_ids[i] " is missing type")
        if (input_types[i] == "SELECT" && select_count[i] == 0) {
          fail("SELECT input " input_ids[i] " declares no values")
        }
      }
      for (i = 1; i <= task_count; i++) {
        if (task_types[i] == "") fail("task " task_ids[i] " is missing type")
        type = task_types[i]
        if (type == "io.kestra.plugin.core.log.Log" && !task_fields[i, "message"]) {
          fail("Log task " task_ids[i] " is missing message")
        } else if (type == "io.kestra.plugin.core.debug.Return" && !task_fields[i, "format"]) {
          fail("Return task " task_ids[i] " is missing format")
        } else if ((type == "io.kestra.plugin.core.flow.Sequential" ||
                    type == "io.kestra.plugin.core.flow.Parallel") && !task_fields[i, "tasks"]) {
          fail("flow wrapper " task_ids[i] " is missing tasks")
        } else if (type == "io.kestra.plugin.core.flow.If" &&
                   (!task_fields[i, "condition"] || !task_fields[i, "then"] || !task_fields[i, "else"])) {
          fail("If task " task_ids[i] " requires condition, then, and else")
        } else if (type == "io.kestra.plugin.core.storage.Write" &&
                   (!task_fields[i, "extension"] || !task_fields[i, "content"])) {
          fail("Write task " task_ids[i] " requires extension and content")
        } else if (type == "io.kestra.plugin.core.execution.Fail" &&
                   (!task_fields[i, "errorMessage"] || !task_fields[i, "retry"])) {
          fail("Fail task " task_ids[i] " requires errorMessage and retry")
        }
      }
      for (pair in task_fields) {
        split(pair, parts, SUBSEP)
        task = parts[1]
        key = parts[2]
        if (!task_field_allowed(task_types[task], key)) {
          fail("task " task_ids[task] " uses unsupported key for its type: " key)
        }
      }
      for (i = 1; i <= task_count; i++) {
        if (task_types[i] == "io.kestra.plugin.core.execution.Fail" &&
            (!retry_fields[i, "type"] || !retry_fields[i, "interval"] ||
             !retry_fields[i, "maxAttempts"] || !retry_fields[i, "maxDuration"] ||
             !retry_fields[i, "warningOnRetry"])) {
          fail("Fail task " task_ids[i] " requires the complete supported retry shape")
        }
      }
      for (i = 1; i <= output_count; i++) {
        if (output_types[i] == "") fail("output is missing type")
        if (output_values[i] == "") fail("output is missing value")
      }
      exit problems
    }
  ' "$file"
}

# fm_kestra_task_records <file>: print the id and plugin type of every task map,
# separated by US. It covers Kestra 1.3.34's flow-level task containers, flowable
# task containers, switch cases, deprecated listener tasks, and DAG task wrappers.
fm_kestra_task_records() {
  awk '
    BEGIN { US = sprintf("%c", 31); count = 0 }
    function indent(line) { match(line, /^[ \t]*/); return RLENGTH }
    function scalar(line, prefix,   value) {
      value = line
      sub(prefix, "", value)
      sub(/[ \t]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      return value
    }
    function clear_from(level,   i) {
      for (i in owners) if ((i + 0) >= level) delete owners[i]
      for (i in current) if ((i + 0) >= level) delete current[i]
    }
    function task_container(level,   i, key) {
      key = owners[level]
      if (key == "tasks" || key == "then" || key == "else" ||
          key == "errors" || key == "finally" || key == "afterExecution" ||
          key == "defaults") return 1
      for (i in owners) {
        if ((i + 0) < level && owners[i] == "cases") return 1
      }
      return 0
    }
    function closest_owner(level,   i, found) {
      found = -1
      for (i in owners) if ((i + 0) < level && (i + 0) > found) found = i + 0
      return found
    }
    function closest_task(level,   i, found) {
      found = -1
      for (i in current) if ((i + 0) < level && (i + 0) > found) found = i + 0
      return found
    }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
      clear_from(0)
      section = $0
      sub(/:.*/, "", section)
      active = section == "tasks" || section == "errors" ||
        section == "finally" || section == "afterExecution" ||
        section == "listeners"
      if (active) owners[0] = section
      next
    }
    !active { next }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    {
      level = indent($0)
      clear_from(level)
    }
    /^[ \t]*[a-zA-Z_][a-zA-Z0-9_]*:[ \t]*$/ {
      key = $0
      sub(/^[ \t]*/, "", key)
      sub(/:.*/, "", key)
      owners[level] = key
      next
    }
    /^[ \t]*-[ \t]+[a-zA-Z_][a-zA-Z0-9_]*:/ {
      parent = closest_owner(level)
      if (parent < 0) next
      key = $0
      sub(/^[ \t]*-[ \t]+/, "", key)
      sub(/:.*/, "", key)
      if (!task_container(parent)) {
        owners[level] = key
        next
      }
      count++
      current[level] = count
      ids[count] = ""
      types[count] = ""
      field_levels[count] = level + 2
      if (key == "id") {
        ids[count] = scalar($0, "^[ \\t]*-[ \\t]+id:[ \\t]*")
      } else if (key == "type") {
        types[count] = scalar($0, "^[ \\t]*-[ \\t]+type:[ \\t]*")
      } else if (key == "task" && $0 ~ /task:[ \t]*$/) {
        wrappers[count] = 1
        field_levels[count] = -1
      }
      next
    }
    /^[ \t]*-[ \t]*/ {
      parent = closest_owner(level)
      if (parent >= 0 && (task_container(parent) || owners[parent] == "listeners")) {
        count++
        ids[count] = ""
        types[count] = ""
      }
      next
    }
    /^[ \t]*id:[ \t]*/ {
      task_level = closest_task(level)
      if (task_level < 0) next
      task = current[task_level]
      if (!wrappers[task]) next
      if (field_levels[task] < 0) field_levels[task] = level
      if (field_levels[task] == level) {
        ids[task] = scalar($0, "^[ \\t]*id:[ \\t]*")
      }
      next
    }
    /^[ \t]*type:[ \t]*/ {
      task_level = closest_task(level)
      if (task_level < 0) next
      task = current[task_level]
      if (field_levels[task] == level) {
        types[task] = scalar($0, "^[ \\t]*type:[ \\t]*")
      }
    }
    END {
      for (i = 1; i <= count; i++) print ids[i] US types[i]
    }
  ' "$1"
}

fm_kestra_task_ids() {
  local record id
  while IFS= read -r record; do
    IFS=$FM_KESTRA_US read -r id _ <<< "$record"
    [ -n "$id" ] && printf '%s\n' "$id"
  done <<< "$(fm_kestra_task_records "$1")"
}

fm_kestra_task_types() {
  local record type
  while IFS= read -r record; do
    IFS=$FM_KESTRA_US read -r _ type <<< "$record"
    [ -n "$type" ] && printf '%s\n' "$type"
  done <<< "$(fm_kestra_task_records "$1")"
}

# fm_kestra_inputs <file>: print one record per declared input, fields separated by
# US (0x1f):
#   id | type | required | min | max | values | validator | default
# `values` is comma-separated. Empty fields stay empty, which is why the separator
# is US and not a tab: bash treats a tab as IFS whitespace and would silently
# collapse consecutive empty fields, shifting every later field left. Consumers
# split with FM_KESTRA_US. An input key the parser does not recognize is emitted as
# `!unknown:<key>` in the id field so the caller refuses the flow rather than
# validating it partially.
FM_KESTRA_US=$(printf '\037')

fm_kestra_inputs() {
  awk '
    BEGIN { US = sprintf("%c", 31) }
    function flush() {
      if (cur_id == "") return
      print cur_id US cur_type US cur_required US cur_min US cur_max US \
        cur_values US cur_validator US cur_default
      cur_id = ""; cur_type = ""; cur_required = ""; cur_min = ""
      cur_max = ""; cur_values = ""; cur_validator = ""; cur_default = ""
      in_values = 0
    }
    function scalar(line,   value) {
      value = line
      sub(/^[^:]*:[ \t]*/, "", value)
      sub(/[ \t]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      return value
    }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
      flush()
      section = $0; sub(/:.*/, "", section)
      next
    }
    section != "inputs" { next }
    /^[ \t]*$/ { next }
    /^[ \t]*#/ { next }
    /^[ \t]*- id:[ \t]*/ {
      flush()
      cur_id = $0
      sub(/^[ \t]*- id:[ \t]*/, "", cur_id)
      sub(/[ \t]+$/, "", cur_id)
      gsub(/^["'\'']|["'\'']$/, "", cur_id)
      next
    }
    in_values && /^[ \t]*-[ \t]+/ {
      value = $0
      sub(/^[ \t]*-[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
      if (cur_values != "") cur_values = cur_values ","
      cur_values = cur_values value
      next
    }
    {
      key = $0
      sub(/^[ \t]+/, "", key)
      sub(/:.*/, "", key)
      in_values = 0
      if (key == "type") { cur_type = scalar($0) }
      else if (key == "required") { cur_required = scalar($0) }
      else if (key == "min") { cur_min = scalar($0) }
      else if (key == "max") { cur_max = scalar($0) }
      else if (key == "validator") { cur_validator = scalar($0) }
      else if (key == "description") { }
      else if (key == "defaults") { cur_default = scalar($0) }
      else if (key == "values") {
        cur_values = ""
        in_values = 1
      }
      else { cur_id = "!unknown:" key }
    }
    END { flush() }
  ' "$1"
}

# --- static flow validation -------------------------------------------------

fm_kestra_task_type_allowed() {
  case "$1" in
    io.kestra.plugin.core.debug.Return|\
    io.kestra.plugin.core.execution.Fail|\
    io.kestra.plugin.core.flow.If|\
    io.kestra.plugin.core.flow.Parallel|\
    io.kestra.plugin.core.flow.Sequential|\
    io.kestra.plugin.core.log.Log|\
    io.kestra.plugin.core.storage.Write)
      return 0
      ;;
  esac
  return 1
}

# An input validator is pre-checked locally with POSIX ERE before any execution is
# created. Kestra evaluates the same pattern as a Java regex, so a pattern using a
# Java-only construct would be checked by two different engines and the local check
# would be the weaker one. Refuse those patterns at deploy time instead.
fm_kestra_validator_is_ere_safe() {
  local rc=0
  case "$1" in
    *'\d'*|*'\w'*|*'\s'*|*'\D'*|*'\W'*|*'\S'*|*'\b'*|*'\B'*|*'\A'*|*'\z'*|*'\Z'*|*'\p'*|*'(?'*)
      return 1 ;;
  esac
  printf '' | grep -Eq -- "^($1)$" || rc=$?
  [ "$rc" -ne 2 ]
}

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

# fm_kestra_check_flow <file> [source-name]: print one `<source>: <problem>` line
# per problem and return non-zero if any were found. Pure static analysis, no
# network, no config.
fm_kestra_check_flow() {
  local file=$1 source=${2:-$1} problems=0 id ns label_value record
  fm_kestra_supported_yaml "$file" "$source" || problems=1
  id=$(fm_kestra_scalar "$file" id)
  ns=$(fm_kestra_scalar "$file" namespace)

  case "$id" in
    '') printf '%s: missing top-level id\n' "$source" >&2; problems=1 ;;
    *[!a-zA-Z0-9_-]*) printf '%s: flow id is not [A-Za-z0-9_-]+: %s\n' "$source" "$id" >&2; problems=1 ;;
  esac
  case "$ns" in
    '') printf '%s: missing top-level namespace\n' "$source" >&2; problems=1 ;;
    *[!a-zA-Z0-9._-]*) printf '%s: namespace is not [A-Za-z0-9._-]+: %s\n' "$source" "$ns" >&2; problems=1 ;;
  esac

  # The readOnly label is what keeps a deployed flow immutable in the Kestra UI.
  # Without it, Git review is advisory rather than binding.
  label_value=$(awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ { section = $0; sub(/:.*/, "", section); next }
    section == "labels" && /^[ \t]*system\.readOnly:[ \t]*/ {
      value = $0
      sub(/^[ \t]*system\.readOnly:[ \t]*/, "", value)
      sub(/[ \t]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
    }
  ' "$file")
  [ "$label_value" = true ] \
    || { printf '%s: missing label system.readOnly: "true"\n' "$source" >&2; problems=1; }

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    local task_id type
    IFS=$FM_KESTRA_US read -r task_id type <<< "$record"
    [ -n "$task_id" ] \
      || { printf '%s: task map is missing id\n' "$source" >&2; problems=1; }
    [ -n "$type" ] \
      || { printf '%s: task %s is missing type\n' "$source" "${task_id:-<unknown>}" >&2; problems=1; continue; }
    if ! fm_kestra_task_type_allowed "$type"; then
      printf '%s: task type outside the core-plugin allow-list for M1-safe tasks: %s\n' \
        "$source" "$type" >&2
      problems=1
    fi
  done <<< "$(fm_kestra_task_records "$file")"

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    local in_id in_type in_required in_min in_max in_values in_validator
    IFS=$FM_KESTRA_US read -r in_id in_type in_required in_min in_max in_values in_validator _ <<< "$record"
    case "$in_id" in
      '!unknown:'*)
        printf '%s: input key this adapter cannot pre-check: %s\n' "$source" "${in_id#!unknown:}" >&2
        problems=1
        continue
        ;;
    esac
    case "$in_required" in
      ''|true|false) : ;;
      *)
        printf '%s: input %s has invalid required value: %s\n' "$source" "$in_id" "$in_required" >&2
        problems=1
        ;;
    esac
    case "$in_type" in
      INT)
        if { [ -n "$in_min" ] && ! fm_kestra_is_integer "$in_min"; } \
          || { [ -n "$in_max" ] && ! fm_kestra_is_integer "$in_max"; }; then
          printf '%s: input %s has a non-integer min/max\n' "$source" "$in_id" >&2
          problems=1
        elif { [ -n "$in_min" ] && ! fm_kestra_is_int32 "$in_min"; } \
          || { [ -n "$in_max" ] && ! fm_kestra_is_int32 "$in_max"; }; then
          printf '%s: input %s has min/max outside the signed 32-bit range\n' "$source" "$in_id" >&2
          problems=1
        elif [ -n "$in_min" ] && [ -n "$in_max" ] \
          && [ "$(fm_kestra_compare_integers "$in_min" "$in_max")" = gt ]; then
          printf '%s: input %s has min greater than max\n' "$source" "$in_id" >&2
          problems=1
        fi
        ;;
      SELECT)
        [ -n "$in_values" ] || { printf '%s: SELECT input %s declares no values\n' "$source" "$in_id" >&2; problems=1; }
        ;;
      STRING)
        if [ -n "$in_validator" ] && ! fm_kestra_validator_is_ere_safe "$in_validator"; then
          printf '%s: input %s uses a validator this adapter cannot pre-check with POSIX ERE: %s\n' \
            "$source" "$in_id" "$in_validator" >&2
          problems=1
        fi
        ;;
      *)
        printf '%s: input %s has an input type this adapter cannot pre-check: %s\n' \
          "$source" "$in_id" "$in_type" >&2
        problems=1
        ;;
    esac
  done <<< "$(fm_kestra_inputs "$file")"

  [ "$problems" -eq 0 ]
}

# --- flow identity resolution -----------------------------------------------

# fm_kestra_resolve_flow <flow-id> <out-var>: resolve the identity against this
# process's immutable HEAD snapshot and store its snapshot path in <out-var>.
fm_kestra_resolve_flow() {
  local want=$1 out_var=$2 file match=""
  case "$want" in
    ''|*[!a-zA-Z0-9_-]*) fm_kestra_die "flow identity is not allow-listed: ${want:-<empty>}" ;;
  esac
  fm_kestra_ensure_flow_snapshot
  for file in "${FM_KESTRA_SNAPSHOT_FILES[@]}"; do
    if [ "$(fm_kestra_scalar "$file" id)" = "$want" ]; then
      match=$file
      break
    fi
  done
  [ -n "$match" ] || fm_kestra_die "flow identity is not allow-listed: $want"
  printf -v "$out_var" '%s' "$match"
}

fm_kestra_flow_is_in_snapshot() {
  local want=$1 file
  fm_kestra_ensure_flow_snapshot
  for file in "${FM_KESTRA_SNAPSHOT_FILES[@]}"; do
    if [ "$(fm_kestra_scalar "$file" id)" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

# --- typed input validation -------------------------------------------------
#
# Every rejection here happens before any HTTP request, so a refused input never
# creates an execution.

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
    local in_id in_type in_required in_min in_max in_values in_validator in_default
    IFS=$FM_KESTRA_US read -r in_id in_type in_required in_min in_max in_values in_validator in_default \
      <<< "$record"
    case "$in_id" in
      '!unknown:'*) fm_kestra_die "flow declares an input this adapter cannot pre-check: ${in_id#!unknown:}" ;;
    esac
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
      if [ "${in_required:-true}" = "true" ] && [ -z "$in_default" ]; then
        fm_kestra_die "missing required input: $in_id"
      fi
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
          fm_kestra_validator_is_ere_safe "$in_validator" \
            || fm_kestra_die "input $in_id has a validator this adapter cannot pre-check"
          printf '%s' "$value" | grep -Eq -- "^($in_validator)$" \
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
# bin/. docs/kestra-seam.md documents the file's shape; no value is committed.

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
  local url=$1 rest hostport host
  case "$url" in
    http://*) rest=${url#http://} ;;
    https://*) rest=${url#https://} ;;
    *) fm_kestra_die "endpoint must be http:// or https://: $url" ;;
  esac
  case "$rest" in
    *@*) fm_kestra_die "endpoint must not embed credentials" ;;
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

# fm_kestra_path_allowed <role> <method> <path>: 0 when the role allows it.
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

fm_kestra_path_allowed() {
  local role=$1 method=$2 path=$3

  # Belt and braces: no role may ever reach a state-changing or secret surface,
  # whatever its own pattern list says.
  fm_kestra_path_has_forbidden_segment "$path" && return 1
  case "$method" in
    DELETE|PUT|PATCH) return 1 ;;
  esac

  local ns=${FM_KESTRA_NAMESPACE:-} tail
  case "$role" in
    deploy)
      # Exact matches, not prefixes: a trailing wildcard after `namespace=` would
      # let an extra query parameter ride along on the update call.
      case "$method $path" in
        'POST /flows/validate') return 0 ;;
        "POST /flows/bulk?delete=false&namespace=$ns") [ -n "$ns" ] && return 0 ;;
      esac
      ;;
    run)
      # Narrowed to one flow inside the one allow-listed namespace, so a caller that
      # built a path by hand can neither reach another namespace nor append a
      # sub-resource to the execution call.
      case "$method $path" in
        "POST /executions/$ns/"*)
          [ -n "$ns" ] || return 1
          tail=${path#"/executions/$ns/"}
          case "$tail" in
            ''|*/*|*'?'*) return 1 ;;
            *) fm_kestra_flow_is_in_snapshot "$tail" && return 0 ;;
          esac
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
              local flow=${tail%%\?*} revision=${tail#*'?revision='}
              revision=${revision%&source=true}
              case "$flow" in ''|*/*|*[!a-zA-Z0-9_-]*) return 1 ;; esac
              case "$revision" in ''|*[!0-9]*) return 1 ;; esac
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
  local method=$1 path=$2 output=$3 netrc="" rc
  shift 3
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
  curl_args+=(--request "$method" "$FM_KESTRA_BASE_URL/api/v1/$FM_KESTRA_TENANT$path")
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
  fm_kestra_curl_request GET "$path" "$output"
}

# fm_kestra_request <role> <method> <path> [structured payload...]
#
# Writes the response body to stdout and returns curl's status. The credential is
# supplied through a mode-0600 config file removed on exit, never through argv.
# Deploy accepts one YAML body file, run accepts only literal name=value form
# fields, and read accepts no payload.
fm_kestra_request() {
  local role=$1 method=$2 path=$3
  shift 3
  command -v curl >/dev/null 2>&1 || fm_kestra_die "curl is required for the Kestra seam" 1

  fm_kestra_path_allowed "$role" "$method" "$path" \
    || fm_kestra_die "refused: $role may not $method $path"

  local body field name
  local request_args=()
  case "$role" in
    deploy)
      [ "$#" -eq 1 ] \
        || fm_kestra_die "refused: deploy requests require exactly one YAML body file"
      body=$1
      [ -f "$body" ] && [ ! -L "$body" ] \
        || fm_kestra_die "refused: deploy body is not a regular file"
      request_args=(-H 'Content-Type: application/x-yaml' --data-binary "@$body")
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

  fm_kestra_curl_request "$method" "$path" "" ${request_args+"${request_args[@]}"}
}
