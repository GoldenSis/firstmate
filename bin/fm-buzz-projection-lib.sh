#!/usr/bin/env bash
# fm-buzz-projection-lib.sh - shared fm-bearings.v1 validation for Buzz shell entry points.
#
# Source this internal library after defining a caller-specific `log` function.
# Both functions take one filesystem path naming the complete projection and
# require `jq`; JSON validation additionally requires `python3`.
# `fm_buzz_validate_projection_json` rejects unreadable, malformed, non-finite,
# or duplicate-key JSON, while `fm_buzz_validate_projection_contract` rejects a
# parsed value outside the shared fm-bearings.v1 base shape.
# Diagnostics are passed to the caller's `log` function, stdout stays empty, and
# each function returns 0 for a valid input or 1 for any read or validation error.
# Sourcing this file has no side effects.

fm_buzz_validate_projection_contract() {
  local projection=$1
  jq -e 'type == "object"' "$projection" >/dev/null 2>&1 || {
    log "the projection root must be an object"
    return 1
  }
  jq -e '.schema == "fm-bearings.v1"' "$projection" >/dev/null 2>&1 || {
    log 'the projection field schema must equal "fm-bearings.v1"'
    return 1
  }
  jq -e 'has("home") and (.home | type == "string")' "$projection" >/dev/null 2>&1 || {
    log "the projection field home must be a string"
    return 1
  }
  jq -e 'has("generated") and (.generated | type == "string")' "$projection" >/dev/null 2>&1 || {
    log "the projection field generated must be a string"
    return 1
  }
  jq -e 'has("prs") and (.prs | type == "string")' "$projection" >/dev/null 2>&1 || {
    log "the projection field prs must be a string"
    return 1
  }
  jq -e '
    has("in_flight")
      and (.in_flight | type == "array")
      and all(.in_flight[];
        type == "object"
          and ((keys | sort) == ["doing", "id", "kind", "state"])
          and (.id | type == "string")
          and (.kind | type == "string")
          and (.state | type == "string")
          and (.doing | type == "string"))
  ' "$projection" >/dev/null 2>&1 || {
    log "the projection field in_flight must be an array of {id,kind,state,doing} strings"
    return 1
  }
  jq -e '
    has("omitted")
      and (.omitted | type == "array")
      and all(.omitted[];
        type == "object"
          and ((keys | sort) == ["reveal", "surface"])
          and (.surface | type == "string" and length > 0)
          and (.reveal | type == "string" and length > 0))
  ' "$projection" >/dev/null 2>&1 || {
    log "the projection field omitted must be an array of {surface,reveal} non-empty strings"
    return 1
  }
}

fm_buzz_validate_projection_json() {
  local projection=$1 duplicate rc
  duplicate=$(python3 - "$projection" <<'PY'
import json
import sys


class DuplicateKey(Exception):
    pass


def reject_duplicate_keys(pairs):
    seen = set()
    for key, _ in pairs:
        if key in seen:
            print(json.dumps(key, ensure_ascii=True))
            raise DuplicateKey
        seen.add(key)
    return dict(pairs)


try:
    with open(sys.argv[1], "rb") as projection:
        json.load(
            projection,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
        )
except DuplicateKey:
    raise SystemExit(42)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(43)
PY
  )
  rc=$?
  case $rc in
    0) return 0 ;;
    42) log "the projection contains duplicate field $duplicate" ;;
    *) log "the projection is not one valid JSON value" ;;
  esac
  return 1
}
