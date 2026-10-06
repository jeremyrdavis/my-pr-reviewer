#!/usr/bin/env bash
# Decides whether a pull request gets an AI review, and normalizes its metadata.
# Runs in the `prepare` job, from the trusted base branch, with read-only permissions.
#
# Inputs (environment):
#   EVENT_NAME     pull_request_target, or workflow_dispatch
#   EVENT_PATH     event payload file (GITHUB_EVENT_PATH) for pull request events
#   REPO           owner/name of this repository
#   GH_TOKEN       token for `gh api` (workflow_dispatch only)
#   DISPATCH_PR    pull request number (workflow_dispatch only)
#   ENABLED        'false' is a kill switch (repo variable AI_REVIEW_ENABLED)
#   TRUST_MODE     'everyone' (default) or 'trusted' (repo variable AI_REVIEW_TRUST)
#   MAX_LINES, MAX_FILES, REVIEW_LABEL   limits and the re-review label
# Outputs ($GITHUB_OUTPUT): run, reason, notify, number, head_repo, head_sha, base_repo,
# base_sha, base_ref, author, title, body_b64.
#
# Everything read from the payload is attacker-controlled on a public repository, so
# identifiers are validated and free text is truncated and single-lined.
set -euo pipefail

EVENT_NAME="${EVENT_NAME:?EVENT_NAME is required}"
REPO="${REPO:?REPO is required}"
ENABLED="${ENABLED:-true}"
TRUST_MODE="${TRUST_MODE:-everyone}"
MAX_LINES="${MAX_LINES:-3000}"
MAX_FILES="${MAX_FILES:-60}"
REVIEW_LABEL="${REVIEW_LABEL:-ai-review}"
out_file="${GITHUB_OUTPUT:-/dev/stdout}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

out() {
  # One line per output: values must not contain newlines.
  printf '%s=%s\n' "$1" "$2" >> "${out_file}"
}

TRUST_MODE="$(tr '[:upper:]' '[:lower:]' <<< "${TRUST_MODE}")"
case "${TRUST_MODE}" in
  everyone | trusted) ;;
  *)
    echo "::warning::Unknown AI_REVIEW_TRUST value; using 'trusted'."
    TRUST_MODE=trusted
    ;;
esac

# --- Load the pull request, from the event payload or the API --------------------
case "${EVENT_NAME}" in
  pull_request_target | pull_request)
    event_path="${EVENT_PATH:?EVENT_PATH is required for pull request events}"
    action="$(jq -r '.action // ""' "${event_path}")"
    label="$(jq -r '.label.name // ""' "${event_path}")"
    pr_json="$(jq -c '.pull_request' "${event_path}")"
    ;;
  workflow_dispatch)
    [[ "${DISPATCH_PR:-}" =~ ^[0-9]+$ ]] || fail "pr-number must be a whole number"
    pr_json="$(gh api "repos/${REPO}/pulls/${DISPATCH_PR}")"
    action="dispatch"
    label=""
    ;;
  *)
    fail "Unsupported event: ${EVENT_NAME}"
    ;;
esac
[[ -n "${pr_json}" && "${pr_json}" != "null" ]] || fail "No pull request found in the event"

field() { jq -r "$1" <<< "${pr_json}"; }

number="$(field '.number')"
head_sha="$(field '.head.sha')"
base_sha="$(field '.base.sha')"
head_repo="$(field '.head.repo.full_name // ""')"
base_repo="$(field '.base.repo.full_name')"
base_ref_raw="$(field '.base.ref')"
author="$(field '.user.login')"
author_type="$(field '.user.type // ""')"
association="$(field '.author_association // ""')"
draft="$(field '.draft // false')"
additions="$(field '.additions // 0')"
deletions="$(field '.deletions // 0')"
changed_files="$(field '.changed_files // 0')"

# --- Validate identifiers: these end up in checkout paths and git commands --------
[[ "${number}" =~ ^[0-9]+$ ]] || fail "Invalid pull request number"
[[ "${head_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid head sha"
[[ "${base_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid base sha"
[[ "${base_repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "Invalid base repository"
[[ -z "${head_repo}" || "${head_repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "Invalid head repository"
[[ "${author}" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || fail "Invalid author login"
[[ "${additions}" =~ ^[0-9]+$ && "${deletions}" =~ ^[0-9]+$ && "${changed_files}" =~ ^[0-9]+$ ]] \
  || fail "Invalid size fields"

# Free text: single line, no control characters, short. The ref is display-only.
title="$(field '.title // ""' | tr '\n\r\t' '   ' | tr -d '\000-\037\177' | cut -c1-200)"
base_ref="${base_ref_raw//[^A-Za-z0-9._\/-]/?}"
body_b64="$(jq -j '.body // ""' <<< "${pr_json}" | head -c 4000 | base64 -w0)"

# --- Decide ----------------------------------------------------------------------
run=true
reason="ok"
notify=""
lines=$((additions + deletions))

if [[ "$(tr '[:upper:]' '[:lower:]' <<< "${ENABLED}")" == "false" ]]; then
  run=false
  reason="AI review is switched off (AI_REVIEW_ENABLED=false)"
elif [[ -z "${head_repo}" ]]; then
  run=false
  reason="the head repository is no longer available"
elif [[ "${action}" == "labeled" ]]; then
  # Adding the review label is an explicit request, so it skips the draft and trust checks.
  if [[ "${label}" != "${REVIEW_LABEL}" ]]; then
    run=false
    reason="the label '${label}' does not request a review"
  fi
elif [[ "${action}" == "dispatch" ]]; then
  : # Only people with write access can dispatch a workflow.
else
  case "${action}" in
    opened | reopened | synchronize | ready_for_review) ;;
    *)
      run=false
      reason="the '${action}' event does not trigger a review"
      ;;
  esac
  if [[ "${run}" == "true" && "${draft}" == "true" ]]; then
    run=false
    reason="the pull request is a draft"
  elif [[ "${run}" == "true" && ( "${author_type}" == "Bot" || "${author}" == *"[bot]" ) ]]; then
    run=false
    reason="the author is a bot"
  elif [[ "${run}" == "true" && "${TRUST_MODE}" == "trusted" ]]; then
    case "${association}" in
      OWNER | MEMBER | COLLABORATOR) ;;
      *)
        run=false
        reason="the author is not trusted; a maintainer can add the '${REVIEW_LABEL}' label to request a review"
        ;;
    esac
  fi
fi

if [[ "${run}" == "true" ]] && (( lines > MAX_LINES || changed_files > MAX_FILES )); then
  run=false
  reason="the pull request is too large to review"
  notify="This pull request changes ${lines} lines in ${changed_files} files, which is over the review limit (${MAX_LINES} lines or ${MAX_FILES} files), so it was not reviewed automatically."
fi

reason="$(tr -d '\000-\037\177' <<< "${reason}" | cut -c1-300)"
echo "Pull request #${number}: run=${run} (${reason})"
[[ "${run}" == "true" ]] || echo "::notice::No AI review for #${number}: ${reason}"

out run "${run}"
out reason "${reason}"
out notify "${notify}"
out number "${number}"
out head_repo "${head_repo}"
out head_sha "${head_sha}"
out base_repo "${base_repo}"
out base_sha "${base_sha}"
out base_ref "${base_ref}"
out author "${author}"
out title "${title}"
out body_b64 "${body_b64}"
