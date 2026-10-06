#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # literals are intentional; `cmd && ok || bad` is a reporting idiom
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="${ROOT}/.github/scripts/resolve-pr.sh"
need_exec "${SCRIPT}" "${TESTS}/stubs/gh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222

# pr_json draft assoc login type additions deletions files [head_repo_json]
pr_json() {
  jq -n --argjson draft "$1" --arg assoc "$2" --arg login "$3" --arg type "$4" \
    --argjson add "$5" --argjson del "$6" --argjson files "$7" --argjson headrepo "${8:-{\"full_name\":\"fork/repo\"\}}" \
    --arg s1 "${SHA1}" --arg s2 "${SHA2}" \
    '{number:7, title:"Fix it", body:"Please review", draft:$draft, author_association:$assoc,
      user:{login:$login, type:$type}, head:{sha:$s1, repo:$headrepo},
      base:{sha:$s2, ref:"main", repo:{full_name:"owner/repo"}},
      additions:$add, deletions:$del, changed_files:$files}'
}
# event action label <pr-json>
event() { jq -n --arg a "$1" --arg l "$2" --argjson pr "$3" '{action:$a, label:{name:$l}, pull_request:$pr}'; }

# resolve <event-json> [ENV=VAL...]: runs the script, leaves outputs in ${T}/out
resolve() {
  local ev="$1"; shift
  printf '%s' "${ev}" > "${T}/event.json"
  : > "${T}/out"
  env EVENT_NAME=pull_request_target EVENT_PATH="${T}/event.json" REPO=owner/repo \
      GITHUB_OUTPUT="${T}/out" "$@" bash "${SCRIPT}" > "${T}/stdout" 2>&1
}
val() { grep -m1 "^$1=" "${T}/out" | cut -d= -f2-; }

PR_OK="$(pr_json false MEMBER alice User 10 5 3)"

resolve "$(event opened '' "${PR_OK}")"; rc=$?
assert_rc "${rc}" 0 "opened by a member: script succeeds"
assert_eq "$(val run)" true "opened by a member: review runs"
assert_eq "$(val number)" 7 "outputs the pull request number"
assert_eq "$(val head_repo)" fork/repo "outputs the head repository"
assert_eq "$(val base_ref)" main "outputs the base ref"

for a in synchronize reopened ready_for_review; do
  resolve "$(event "${a}" '' "${PR_OK}")"; assert_eq "$(val run)" true "${a} runs a review"
done
resolve "$(event edited '' "${PR_OK}")"; assert_eq "$(val run)" false "an 'edited' event does not run a review"

resolve "$(event opened '' "$(pr_json true MEMBER alice User 1 1 1)")"
assert_eq "$(val run)" false "draft pull requests are skipped"
assert_contains "$(val reason)" draft "the reason says it is a draft"

resolve "$(event opened '' "$(pr_json false NONE 'dependabot[bot]' Bot 1 1 1)")"
assert_eq "$(val run)" false "bot authors are skipped (type Bot)"
resolve "$(event opened '' "$(pr_json false NONE 'renovate[bot]' User 1 1 1)")"
assert_eq "$(val run)" false "bot authors are skipped (login ends with [bot])"

echo "-- labels"
resolve "$(event labeled bug "${PR_OK}")"; assert_eq "$(val run)" false "an unrelated label does nothing"
resolve "$(event labeled ai-review "${PR_OK}")"; assert_eq "$(val run)" true "the ai-review label requests a review"
resolve "$(event labeled ai-review "$(pr_json true NONE stranger User 1 1 1)")" AI_REVIEW_TRUST=trusted
assert_eq "$(val run)" true "the label overrides the draft and trust checks"

echo "-- trust modes"
STRANGER="$(pr_json false NONE stranger User 5 5 2)"
resolve "$(event opened '' "${STRANGER}")"
assert_eq "$(val run)" true "default mode (everyone): a stranger's pull request is reviewed"
resolve "$(event opened '' "${STRANGER}")" TRUST_MODE=everyone; assert_eq "$(val run)" true "everyone mode: a stranger is reviewed"
resolve "$(event opened '' "${STRANGER}")" TRUST_MODE=trusted
assert_eq "$(val run)" false "trusted mode: a stranger is not reviewed automatically"
assert_contains "$(val reason)" "ai-review" "trusted mode: the reason names the label to use"
for assoc in OWNER MEMBER COLLABORATOR; do
  resolve "$(event opened '' "$(pr_json false "${assoc}" bob User 1 1 1)")" TRUST_MODE=trusted
  assert_eq "$(val run)" true "trusted mode: ${assoc} is reviewed"
done
resolve "$(event opened '' "$(pr_json false FIRST_TIME_CONTRIBUTOR carol User 1 1 1)")" TRUST_MODE=trusted
assert_eq "$(val run)" false "trusted mode: a first-time contributor is not reviewed"
resolve "$(event opened '' "${STRANGER}")" TRUST_MODE=Trusted; assert_eq "$(val run)" false "the trust mode is case-insensitive"
resolve "$(event opened '' "${STRANGER}")" TRUST_MODE=garbage; assert_eq "$(val run)" false "an unknown trust mode fails closed (treated as trusted)"

echo "-- kill switch"
resolve "$(event opened '' "${PR_OK}")" ENABLED=false; assert_eq "$(val run)" false "ENABLED=false stops reviews"
resolve "$(event opened '' "${PR_OK}")" ENABLED=FALSE; assert_eq "$(val run)" false "ENABLED is case-insensitive"
resolve "$(event labeled ai-review "${PR_OK}")" ENABLED=false; assert_eq "$(val run)" false "the kill switch also beats the label"
resolve "$(event opened '' "${PR_OK}")" ENABLED=; assert_eq "$(val run)" true "an empty ENABLED (unset variable) means enabled"

echo "-- size limits"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 2000 1500 5)")"
assert_eq "$(val run)" false "too many changed lines: skipped"
assert_contains "$(val notify)" "3500 lines" "too many lines: a notice is produced"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 10 10 61)")"
assert_eq "$(val run)" false "too many files: skipped"
assert_contains "$(val notify)" "61 files" "too many files: a notice is produced"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 2000 1500 5)")" MAX_LINES=10000
assert_eq "$(val run)" true "MAX_LINES raises the limit"
resolve "$(event opened '' "${PR_OK}")"; assert_eq "$(val notify)" "" "no notice when the pull request is reviewed"
resolve "$(event opened '' "$(pr_json true MEMBER alice User 9999 1 1)")"; assert_eq "$(val notify)" "" "a draft is skipped silently, even if large"

echo "-- hostile input"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 1 1 1 | jq --arg t $'Evil\nrun=true\r\x01 title' '.title=$t')")"
assert_eq "$(grep -c '^run=' "${T}/out")" 1 "a newline in the title can't inject an output"
assert_not_contains "$(val title)" $'\r' "the title has no carriage return"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 1 1 1 | jq --arg b "$(head -c 9000 /dev/zero | tr '\0' 'x')" '.body=$b')")"
assert_eq "$(val body_b64 | base64 -d | wc -c | tr -d ' ')" 4000 "the body is cut to 4000 bytes"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 1 1 1 | jq '.base.ref="main\nrun=true"')")"
assert_eq "$(grep -c '^run=' "${T}/out")" 1 "a newline in the base ref can't inject an output"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 1 1 1 | jq '.head.sha="abc; rm -rf /"')")"; rc=$?
assert_nonzero "${rc}" "an invalid head sha is rejected"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 1 1 1 | jq '.head.repo.full_name="evil/repo; echo hi"')")"; rc=$?
assert_nonzero "${rc}" "an invalid head repository is rejected"
resolve "$(event opened '' "$(pr_json false MEMBER 'a b' User 1 1 1)")"; rc=$?
assert_nonzero "${rc}" "an invalid author login is rejected"
resolve "$(event opened '' "$(pr_json false MEMBER alice User 1 1 1 null)")"; rc=$?
assert_rc "${rc}" 0 "a deleted fork (head repo null) is not an error"
assert_eq "$(val run)" false "a deleted fork is skipped"

echo "-- workflow_dispatch"
mkdir -p "${T}/stub"
export STUB_DIR="${T}/stub"
pr_json true NONE 'some-bot[bot]' Bot 1 1 1 > "${STUB_DIR}/pr.json"
: > "${T}/out"
env EVENT_NAME=workflow_dispatch REPO=owner/repo DISPATCH_PR=7 GITHUB_OUTPUT="${T}/out" PATH="${TESTS}/stubs:${PATH}" bash "${SCRIPT}" > "${T}/stdout" 2>&1; rc=$?
assert_rc "${rc}" 0 "dispatch: script succeeds"
assert_eq "$(val run)" true "dispatch reviews even a draft from a bot (the dispatcher has write access)"
assert_contains "$(cat "${STUB_DIR}/gh.log")" "repos/owner/repo/pulls/7" "dispatch reads the pull request from the API"
for bad in "" abc "7; id" "-1"; do
  env EVENT_NAME=workflow_dispatch REPO=owner/repo DISPATCH_PR="${bad}" GITHUB_OUTPUT="${T}/out" PATH="${TESTS}/stubs:${PATH}" bash "${SCRIPT}" > /dev/null 2>&1; rc=$?
  assert_nonzero "${rc}" "dispatch rejects pr-number '${bad}'"
done
env EVENT_NAME=issues REPO=owner/repo GITHUB_OUTPUT="${T}/out" bash "${SCRIPT}" > /dev/null 2>&1; rc=$?
assert_nonzero "${rc}" "an unsupported event is rejected"
finish
