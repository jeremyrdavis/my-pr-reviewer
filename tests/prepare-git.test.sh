#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # literals are intentional; `cmd && ok || bad` is a reporting idiom
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="${ROOT}/.github/scripts/prepare-git.sh"
need_exec "${SCRIPT}"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.x
g() { git -C "$1" "${@:2}"; }

# upstream: A, then B (the base). fork: A, then C (the pull request).
git init -q "${T}/upstream" -b main
echo one > "${T}/upstream/f.txt"; g "${T}/upstream" add -A; g "${T}/upstream" commit -qm A
A="$(g "${T}/upstream" rev-parse HEAD)"
git clone -q "${T}/upstream" "${T}/pr"
echo two > "${T}/upstream/g.txt"; g "${T}/upstream" add -A; g "${T}/upstream" commit -qm B
B="$(g "${T}/upstream" rev-parse HEAD)"
echo change > "${T}/pr/pr-change.txt"; g "${T}/pr" add -A; g "${T}/pr" commit -qm C
C="$(g "${T}/pr" rev-parse HEAD)"
g "${T}/pr" checkout -q --detach "${C}"

assert_eq "$(g "${T}/pr" cat-file -t "${B}" 2>&1 | head -c 5)" "fatal" "setup: the fork does not contain the base commit"

run() { env PR_DIR="${T}/pr" BASE_REPO=owner/repo BASE_SHA="$1" HEAD_SHA="$2" BASE_FETCH_URL="${T}/upstream" "${@:3}" bash "${SCRIPT}" > "${T}/stdout" 2>&1; }

run "${B}" "${C}"; rc=$?
assert_rc "${rc}" 0 "the script succeeds"
assert_eq "$(g "${T}/pr" rev-parse pr-base)" "${B}" "pr-base is the base commit, fetched from the base repository"
assert_eq "$(g "${T}/pr" rev-parse pr-head)" "${C}" "pr-head is the head commit"
assert_eq "$(g "${T}/pr" rev-parse --abbrev-ref HEAD)" "pr-head" "pr-head is checked out"
assert_eq "$(g "${T}/pr" diff --name-only pr-base...pr-head)" "pr-change.txt" "the three-dot diff shows only the pull request's change"
assert_contains "$(cat "${T}/stdout")" "Merge base: ${A}" "reports the merge base"

echo "-- a clone carries the branches, so the agent can diff"
git clone -q "${T}/pr" "${T}/sandbox-clone"
assert_eq "$(g "${T}/sandbox-clone" diff --name-only origin/pr-base...HEAD)" "pr-change.txt" "origin/pr-base...HEAD works in a clone"

echo "-- running it again is harmless"
run "${B}" "${C}"; rc=$?; assert_rc "${rc}" 0 "idempotent"

echo "-- bad input"
run "not-a-sha" "${C}"; rc=$?; assert_nonzero "${rc}" "an invalid base sha is rejected"
run "${B}" "${C}; id"; rc=$?; assert_nonzero "${rc}" "an invalid head sha is rejected"
run "${B}" "${C}" BASE_REPO='a/b;id'; rc=$?; assert_nonzero "${rc}" "an invalid base repository is rejected"
run "${B}" "${C}" PR_DIR="${T}/not-a-repo"; rc=$?; assert_nonzero "${rc}" "a directory that isn't a git checkout is rejected"
finish
