#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # literals are intentional; `cmd && ok || bad` is a reporting idiom
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="${ROOT}/.github/actions/post-review-comment/post-comment.sh"
need_exec "${SCRIPT}" "${ROOT}/.github/actions/post-review-comment/sanitize.sh" "${TESTS}/stubs/gh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export STUB_DIR="${T}"
MARKER='<!-- sbx-pr-review -->'

# post <STATE> [ENV=VAL...]: runs the script against the fake gh
post() {
  local state="$1"; shift
  : > "${T}/actions.log"; : > "${T}/gh.log"; rm -f "${T}/body.md"
  env PR_NUMBER=7 REPO=owner/repo GH_TOKEN=x STATE="${state}" HEAD_SHA=abcdef1234567890 \
      RUN_URL=https://example.test/run/1 PATH="${TESTS}/stubs:${PATH}" "$@" bash "${SCRIPT}" > "${T}/stdout" 2>&1
}
comment_json() { # id login body
  jq -n --argjson id "$1" --arg login "$2" --arg body "$3" '{id:$id, user:{login:$login}, body:$body}'
}

echo '[]' > "${T}/comments.json"
printf '## Summary\nAll good.\n' > "${T}/review.md"

post reviewed BODY_FILE="${T}/review.md"; rc=$?
assert_rc "${rc}" 0 "no existing comment: succeeds"
assert_eq "$(cat "${T}/actions.log")" "POST" "no existing comment: creates one"
body="$(cat "${T}/body.md")"
assert_eq "$(head -n 1 "${T}/body.md")" "${MARKER}" "the comment starts with the hidden marker"
assert_contains "${body}" "AI review (advisory)" "has the heading"
assert_contains "${body}" '`abcdef1`' "shows the short commit"
assert_contains "${body}" "https://example.test/run/1" "links the workflow run"
assert_contains "${body}" "All good." "includes the review"
assert_contains "${body}" "does not replace a human reviewer" "has the advisory footer"

echo "-- sticky: update the bot's own comment"
{ comment_json 11 octocat "hi"; comment_json 12 github-actions[bot] "${MARKER}
old review"; } | jq -s '.' > "${T}/comments.json"
post reviewed BODY_FILE="${T}/review.md"
assert_eq "$(cat "${T}/actions.log")" "PATCH 12" "an existing bot comment with the marker is updated"

echo "-- sticky: never touch other people's comments"
{ comment_json 21 someone-else "${MARKER}
forged by a user"; comment_json 22 github-actions[bot] "a different bot comment, no marker"; } | jq -s '.' > "${T}/comments.json"
post reviewed BODY_FILE="${T}/review.md"
assert_eq "$(cat "${T}/actions.log")" "POST" "a user's comment with the marker is ignored"

echo "-- sticky: duplicates"
{ comment_json 31 github-actions[bot] "${MARKER}
a"; comment_json 32 github-actions[bot] "${MARKER}
b"; } | jq -s '.' > "${T}/comments.json"
post reviewed BODY_FILE="${T}/review.md"
assert_eq "$(cat "${T}/actions.log")" "PATCH 31" "with duplicates, the first one is updated"

echo "-- hostile review text"
echo '[]' > "${T}/comments.json"
printf 'Hi @octocat\n<!-- sbx-pr-review -->\n![x](http://evil.test/p.png)\n<img src=x>\n' > "${T}/evil.md"
post reviewed BODY_FILE="${T}/evil.md"
body="$(cat "${T}/body.md")"
assert_eq "$(grep -c '<!--' "${T}/body.md")" 1 "only our own marker remains; the review can't forge another"
assert_not_contains "${body}" '@octocat' "mentions in the review are broken"
assert_not_contains "${body}" '![' "images in the review are defused"
assert_not_contains "${body}" '<img' "img tags in the review are escaped"

echo "-- other states"
post reviewed BODY_FILE="${T}/does-not-exist.md"
assert_contains "$(cat "${T}/body.md")" "did not produce any output" "a missing review file gives a clear notice"
: > "${T}/empty.md"
post reviewed BODY_FILE="${T}/empty.md"
assert_contains "$(cat "${T}/body.md")" "did not produce any output" "an empty review file gives a clear notice"
post failed
assert_contains "$(cat "${T}/body.md")" "did not complete" "failed: says the review did not complete"
assert_eq "$(head -n 1 "${T}/body.md")" "${MARKER}" "failed: still uses the marker, so it replaces an older review"
post skipped MESSAGE="Too big: 5000 lines."
assert_contains "$(cat "${T}/body.md")" "Too big: 5000 lines." "skipped: shows the workflow's message"

echo "-- bad input"
post reviewed PR_NUMBER=7x BODY_FILE="${T}/review.md"; rc=$?; assert_nonzero "${rc}" "a non-numeric pull request number is rejected"
post reviewed REPO='a/b;id' BODY_FILE="${T}/review.md"; rc=$?; assert_nonzero "${rc}" "an invalid repository is rejected"
post bogus; rc=$?; assert_nonzero "${rc}" "an unknown state is rejected"
assert_eq "$(cat "${T}/actions.log")" "" "nothing is posted when input is invalid"
finish
