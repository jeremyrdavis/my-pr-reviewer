#!/usr/bin/env bash
# Tiny assertion helpers shared by the tests.
# shellcheck disable=SC2034  # TESTS is used by the scripts that source this file
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() { # actual expected message
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi
}
assert_contains() { # haystack needle message
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else bad "$3 (missing '$2')"; fi
}
assert_not_contains() { # haystack needle message
  if [[ "$1" != *"$2"* ]]; then ok "$3"; else bad "$3 (found '$2')"; fi
}
assert_rc() { # actual-rc expected-rc message
  if [[ "$1" -eq "$2" ]]; then ok "$3"; else bad "$3 (exit code $1, expected $2)"; fi
}
assert_nonzero() { # actual-rc message
  if [[ "$1" -ne 0 ]]; then ok "$2"; else bad "$2 (expected a failure, got exit code 0)"; fi
}

finish() {
  echo
  echo "${pass} passed, ${fail} failed"
  [[ "${fail}" -eq 0 ]]
}

# Repository root (the directory that holds .github/).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="${ROOT}/tests"

# Fail fast if a script under test is missing or not executable. Without this, "output
# must not contain X" assertions would pass on empty output from a script that never ran.
need_exec() {
  local f
  for f in "$@"; do
    if [[ ! -x "${f}" ]]; then
      echo "  FAIL  ${f} is missing or not executable"
      exit 1
    fi
  done
}
