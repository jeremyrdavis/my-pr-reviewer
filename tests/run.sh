#!/usr/bin/env bash
# Runs every test in this directory. None of them needs sbx, Docker, or network access.
# Usage: ./tests/run.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
status=0
for t in sanitize resolve-pr post-comment build-prompt prepare-git run-agent; do
  echo "== ${t}"
  bash "./${t}.test.sh" || status=1
done
echo
if [[ "${status}" -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "${status}"
