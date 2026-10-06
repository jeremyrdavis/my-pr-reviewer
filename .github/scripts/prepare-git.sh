#!/usr/bin/env bash
# Prepares the checked-out pull request so the agent can diff it inside the sandbox.
#
# The sandbox gets a git clone of PR_DIR. A clone carries every local branch as
# `origin/<branch>`, so this script creates:
#   pr-base  the pull request's base commit (fetched from the base repository, because a
#            fork may not contain it)
#   pr-head  the head commit, checked out
# The agent then reads the change with `git diff origin/pr-base...HEAD`.
#
# Only git plumbing runs here, and nothing from the pull request is executed: hooks and
# config live in the fresh .git directory, not in the pull request's files.
#
# Inputs (environment): PR_DIR, BASE_REPO, BASE_SHA, HEAD_SHA, and optionally GH_TOKEN
# (needed to fetch from a private base repository) and BASE_FETCH_URL (default:
# $GITHUB_SERVER_URL/$BASE_REPO.git, which also covers GitHub Enterprise Server).
set -euo pipefail

: "${PR_DIR:?}" "${BASE_REPO:?}" "${BASE_SHA:?}" "${HEAD_SHA:?}"
[[ "${BASE_SHA}" =~ ^[0-9a-f]{40}$ && "${HEAD_SHA}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::Invalid sha"; exit 1; }
[[ "${BASE_REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "::error::Invalid base repository"; exit 1; }
[[ -d "${PR_DIR}/.git" ]] || { echo "::error::${PR_DIR} is not a git checkout"; exit 1; }

git_pr() { git -C "${PR_DIR}" "$@"; }

server_url="${GITHUB_SERVER_URL:-https://github.com}"
BASE_FETCH_URL="${BASE_FETCH_URL:-${server_url}/${BASE_REPO}.git}"

echo "::group::Fetch the base commit"
fetch_args=(--no-tags --quiet)
if [[ -n "${GH_TOKEN:-}" ]]; then
  # Same scheme actions/checkout uses; the header is not echoed.
  auth="$(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 -w0)"
  git_pr -c "http.${server_url}/.extraheader=AUTHORIZATION: basic ${auth}" \
    fetch "${fetch_args[@]}" "${BASE_FETCH_URL}" "${BASE_SHA}"
else
  git_pr fetch "${fetch_args[@]}" "${BASE_FETCH_URL}" "${BASE_SHA}"
fi
echo "::endgroup::"

git_pr branch --force pr-base "${BASE_SHA}"
git_pr checkout --quiet -B pr-head "${HEAD_SHA}"

if merge_base="$(git_pr merge-base pr-base pr-head)"; then
  echo "Merge base: ${merge_base}"
else
  echo "::warning::pr-base and pr-head share no history; the agent will use a two-dot diff."
fi
git_pr --no-pager diff --stat --no-ext-diff --no-textconv pr-base...pr-head | tail -n 20 || true
