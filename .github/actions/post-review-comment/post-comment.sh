#!/usr/bin/env bash
# Creates or updates ONE sticky review comment on a pull request.
# Runs in a job that has pull-requests: write, but no agent and no sandbox.
#
# Inputs (environment):
#   PR_NUMBER, REPO, GH_TOKEN, HEAD_SHA, RUN_URL
#   STATE      reviewed | failed | skipped
#   BODY_FILE  the agent's review (STATE=reviewed)
#   MESSAGE    notice text from the workflow (STATE=skipped), trusted
#   MARKER     hidden first line that identifies the comment (default below)
#
# Only comments written by github-actions[bot] that start with the marker are ever
# edited, so a user can't make this script rewrite their own comment, or anyone else's.
set -euo pipefail

: "${PR_NUMBER:?}" "${REPO:?}" "${STATE:?}"
MARKER="${MARKER:-<!-- sbx-pr-review -->}"
HEAD_SHA="${HEAD_SHA:-}"
RUN_URL="${RUN_URL:-}"
MESSAGE="${MESSAGE:-}"
BODY_FILE="${BODY_FILE:-}"

[[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || { echo "::error::Invalid pull request number"; exit 1; }
[[ "${REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "::error::Invalid repository"; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

short_sha="${HEAD_SHA:0:7}"
subtitle="Copilot running in a Docker Sandbox"
[[ -z "${short_sha}" ]] || subtitle="Commit \`${short_sha}\` · ${subtitle}"
[[ -z "${RUN_URL}" ]] || subtitle="${subtitle} · [workflow run](${RUN_URL})"

case "${STATE}" in
  reviewed)
    if [[ -n "${BODY_FILE}" && -s "${BODY_FILE}" ]]; then
      content="$("${here}/sanitize.sh" < "${BODY_FILE}")"
    else
      content="The review ran but did not produce any output. See the workflow run for details."
    fi
    ;;
  failed)
    content="The automated review did not complete. See the workflow run for details."
    ;;
  skipped)
    content="${MESSAGE:-This pull request was not reviewed automatically.}"
    ;;
  *)
    echo "::error::STATE must be reviewed, failed or skipped"
    exit 1
    ;;
esac

comment="$(mktemp)"
trap 'rm -f "${comment}"' EXIT
{
  echo "${MARKER}"
  echo "### AI review (advisory)"
  echo "<sub>${subtitle}</sub>"
  echo
  printf '%s\n' "${content}"
  echo
  echo "---"
  echo "<sub>Automated review. It can be wrong and does not replace a human reviewer.</sub>"
} > "${comment}"

# Find our comment: bot-owned and starting with the marker.
existing_id="$(
  gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
    | jq -r --arg marker "${MARKER}" \
      '.[] | select(.user.login == "github-actions[bot]") | select(.body | startswith($marker)) | .id' \
    | head -n 1
)"

if [[ -n "${existing_id}" ]]; then
  [[ "${existing_id}" =~ ^[0-9]+$ ]] || { echo "::error::Unexpected comment id"; exit 1; }
  echo "Updating comment ${existing_id}"
  gh api --method PATCH "repos/${REPO}/issues/comments/${existing_id}" -F "body=@${comment}" > /dev/null
else
  echo "Creating a new comment"
  gh api --method POST "repos/${REPO}/issues/${PR_NUMBER}/comments" -F "body=@${comment}" > /dev/null
fi
