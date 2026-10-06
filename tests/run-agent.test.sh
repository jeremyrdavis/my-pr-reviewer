#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # literals are intentional; `cmd && ok || bad` is a reporting idiom
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="${ROOT}/.github/actions/sbx-agent/run-agent.sh"
need_exec "${SCRIPT}" "${TESTS}/stubs/sbx" "${TESTS}/stubs/docker"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export STUB_DIR="${T}/stub"
mkdir -p "${STUB_DIR}"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.x

# Job workspace holds ./pr (the repository to review); the prompt lives elsewhere.
WS="${T}/work"
mkdir -p "${WS}/pr"
git init -q "${WS}/pr" -b main
echo "class A {}" > "${WS}/pr/A.java"
git -C "${WS}/pr" add -A && git -C "${WS}/pr" commit -qm base
printf 'Review this pull request.\nSecond line with "quotes" and $dollars.\n' > "${T}/prompt.md"

# agent [ENV=VAL...]: runs the script with the fake sbx; outputs land in ${T}/out*
agent() {
  : > "${STUB_DIR}/calls.log"; : > "${T}/gout"; rm -rf "${T}/out"
  env PATH="${TESTS}/stubs:${PATH}" GITHUB_WORKSPACE="${WS}" GITHUB_OUTPUT="${T}/gout" \
      GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 DOCKER_USERNAME=u DOCKER_PAT=SECRETPAT COPILOT_TOKEN=SECRETCOPILOT \
      PROMPT_FILE="${T}/prompt.md" WORKSPACE=pr RESULT_PATH=REVIEW.md OUT_DIR="${T}/out" \
      ALLOWED_HOSTS=$'github.com\n*.githubcopilot.com repo1.maven.org' "$@" \
      bash "${SCRIPT}" > "${T}/stdout" 2>&1
}
gout() { grep "^$1=" "${T}/gout" | tail -1 | cut -d= -f2-; }

echo "-- happy path"
agent; rc=$?
assert_rc "${rc}" 0 "the agent run succeeds"
assert_eq "$(gout has-result)" true "has-result is true"
assert_contains "$(cat "${T}/out/result.md")" "Looks good." "the review file is copied out"
assert_contains "$(cat "${T}/out/agent.log")" "agent finished" "the agent output is kept in agent.log"
assert_contains "$(cat "${STUB_DIR}/calls.log")" "create workspace: ${WS}/pr" "the 'pr' workspace (relative to the job directory) is cloned"
assert_eq "$(cat "${STUB_DIR}/prompt.txt")" "$(cat "${T}/prompt.md")" "the prompt (absolute path) reaches the agent unchanged"
assert_contains "$(cat "${STUB_DIR}/calls.log")" "sbx rm --force" "the sandbox is removed at the end"
assert_eq "$(grep -c 'SECRETPAT\|SECRETCOPILOT' "${T}/stdout" "${STUB_DIR}/calls.log" | tr -d '\n')" "${T}/stdout:0${STUB_DIR}/calls.log:0" "secrets never appear in the log"
assert_contains "$(cat "${T}/stdout")" "Copied REVIEW.md" "reports the copy"

echo "-- relative prompt path resolves against the job directory"
mkdir -p "${WS}/trusted"; cp "${T}/prompt.md" "${WS}/trusted/p.md"
agent PROMPT_FILE=trusted/p.md; rc=$?; assert_rc "${rc}" 0 "a relative prompt path works"

echo "-- failure paths"
agent STUB_AGENT=fail; rc=$?
assert_nonzero "${rc}" "an agent failure fails the step"
assert_contains "$(cat "${T}/stdout")" "The agent exited with code 1" "the failure message names the exit code"
assert_eq "$(gout has-result)" false "no result after a failure"
assert_contains "$(cat "${STUB_DIR}/calls.log")" "sbx rm --force" "the sandbox is still removed after a failure"

agent STUB_AGENT=noresult; rc=$?
assert_rc "${rc}" 0 "an agent that writes no result does not fail the step"
assert_eq "$(gout has-result)" false "has-result is false when the file is missing"
assert_contains "$(cat "${T}/stdout")" "did not write REVIEW.md" "a warning explains it"

agent STUB_AGENT=symlink; rc=$?
assert_eq "$(gout has-result)" false "a symlinked result file is not followed"

agent STUB_AGENT=big; rc=$?
assert_rc "${rc}" 0 "an oversize result does not fail the step"
assert_eq "$(wc -c < "${T}/out/result.md" | tr -d ' ')" 200000 "an oversize result is capped at 200000 bytes"

echo "-- network policy"
agent STUB_POLICY=governed; rc=$?
assert_rc "${rc}" 0 "organization governance refusing local allow rules is not a failure"
assert_contains "$(cat "${T}/stdout")" "managed by your Docker organization" "a notice explains it"
assert_eq "$(gout has-result)" true "the run still completes under governance"
agent STUB_POLICY=broken; rc=$?
assert_nonzero "${rc}" "any other policy error still fails"
assert_eq "$(grep -c '^sbx exec' "${STUB_DIR}/calls.log")" 0 "the agent is not started after a policy error"
assert_eq "$(grep -c '^sbx create' "${STUB_DIR}/calls.log")" 0 "no sandbox is created after a policy error"

echo "-- input validation (none of these may start sbx)"
for bad in "/etc/passwd" "../x" "a/../b" "a b" "a;id" '$(id)' ".." ; do
  agent RESULT_PATH="${bad}"; rc=$?
  assert_nonzero "${rc}" "result-path '${bad}' is rejected"
done
assert_eq "$(wc -l < "${STUB_DIR}/calls.log" | tr -d ' ')" 0 "sbx was never called for rejected input"
agent RESULT_PATH=out/review.md; rc=$?; assert_rc "${rc}" 0 "a nested relative result path is accepted"
agent COPILOT_TOKEN=; rc=$?
assert_nonzero "${rc}" "an empty Copilot token is rejected"
assert_contains "$(cat "${T}/stdout")" "'copilot-token' input is empty" "the message names the input"
agent DOCKER_PAT= COPILOT_TOKEN= RESULT_PATH=; rc=$?
assert_eq "$(grep -c "input is empty" "${T}/stdout")" 3 "every empty input is reported at once"
agent NETWORK_PRESET=wide-open; rc=$?; assert_nonzero "${rc}" "an unknown network preset is rejected"
agent AGENT_TIMEOUT_MINUTES=abc; rc=$?; assert_nonzero "${rc}" "a non-numeric timeout is rejected"
agent PROMPT_FILE="${T}/nope.md"; rc=$?; assert_nonzero "${rc}" "a missing prompt file is rejected"
agent WORKSPACE=nope; rc=$?; assert_nonzero "${rc}" "a missing workspace is rejected"
finish
