# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GitHub Actions workflow that reviews pull requests with a Copilot agent running inside a Docker Sandbox (`sbx`) microVM, and posts the findings as one sticky comment. `README.md` explains the design and the threat model; `DEMO.md` is the presenter script. This project was built in a subdirectory (`pr-reviewer/`) of a companion "explorer" demo and is laid out like a repository root, so every path here is relative to it. It is meant to be moved into its own repository.

## Rules that protect the security model

- **Never execute anything from the pull request on the runner.** The pull request is checked out to `./pr` and is only passed to `sbx create --clone`. Scripts, prompt and actions come from `./trusted` (the base branch). Don't add a step that runs a file from `./pr`.
- **Never put pull request text (title, body, branch names, labels) inside a `run:` script or an `${{ }}` that ends up in one.** Pass it through `env:`. `resolve-pr.sh` validates identifiers and single-lines free text; keep it that way.
- The agent job keeps `contents: read` only. Anything that writes (the comment) lives in the separate `comment` job, which runs no agent and no sandbox.
- Treat the agent's output as untrusted: it always goes through `sanitize.sh` before it is posted. Only comments from `github-actions[bot]` that start with the marker are ever edited.
- Third-party actions are pinned by commit SHA resolved with `git ls-remote`; never invent a SHA.
- The workflow triggers on `pull_request_target`, so it only takes effect from the default branch.

## Layout

- `.github/workflows/pr-review.yml`: jobs `prepare`, `review`, `comment`. Also `kvm-probe.yml`, a manual `/dev/kvm` check.
- `.github/scripts/`: `resolve-pr.sh` (gates and metadata for both triggers), `prepare-git.sh` (fetches the base commit and creates the `pr-base` and `pr-head` branches, which a clone carries as `origin/*`), `build-prompt.sh` (trusted template plus an untrusted-data block with random markers).
- `.github/prompts/pr-review.md`: the trusted review prompt. It makes the agent write `REVIEW.md`.
- `.github/actions/sbx-agent/`: installs `docker-sbx`, starts the daemon, logs in, applies the network policy, stores the Copilot PAT as the sbx `github` secret, runs `sbx create --clone`, then `sbx exec <name> copilot --yolo -p <prompt>`, and copies one result file out as base64 between random markers. Always use `sbx exec`, never `sbx run`: `sbx run` swallows the agent's output without a TTY.
- `.github/actions/post-review-comment/`: `sanitize.sh` and `post-comment.sh` (create or update the sticky comment).
- `src/`, `pom.xml`, `REQUIREMENTS.md`, `scripts/test-in-docker.sh`: a small Java app that is the review material.
- `tests/`: tests for the scripts above, with fake `sbx`, `gh` and `docker` in `tests/stubs/`.

## Commands

- Workflow script tests (no sbx, Docker or network needed): `./tests/run.sh`, or one file, for example `bash tests/resolve-pr.test.sh`.
- The sample app's tests (Docker only): `./scripts/test-in-docker.sh`, or one test, for example `./scripts/test-in-docker.sh -Dtest=RegistrationServiceIT#rejectsExactDuplicate` (extra arguments pass through to Maven before the `test` goal).
- Lint (the tools aren't installed locally; run them in containers): `koalaman/shellcheck` with `-x -P SCRIPTDIR` on every `*.sh` and `tests/stubs/*`; `rhysd/actionlint` with the workflow files as explicit arguments (it needs a git repo, or explicit paths); `yamllint` (relaxed, no line-length rule) on `.github`.

## Conventions

- Shell scripts use `set -euo pipefail` and LF line endings (`.gitattributes`). With `pipefail`, avoid `cmd | grep -q` and don't let a tool that warns and exits non-zero (like `iconv` on a cut character) end a pipeline. Capture the output first, or guard it.
- Scripts must be executable (`chmod +x`). The tests' `need_exec` fails loudly if one isn't, because "must not contain X" assertions pass vacuously on empty output.
- sbx facts that are easy to get wrong: presets are `allow-all`, `balanced`, `deny-all`. Unmatched requests ask for human approval, so a CI allowlist must be complete. Under Docker organization governance only org allow rules grant access, local allow rules are inactive, and `sbx policy allow` exits with "managed by your organization" (the action treats that as a notice). Org filesystem rules govern workspace mounts only.
- Repo variables: `AI_REVIEW_ENABLED`, `AI_REVIEW_TRUST` (`everyone` default or `trusted`), `AI_REVIEW_TEST_COMMAND` (default `./scripts/test-in-docker.sh`, `none` skips tests). GitHub can't tell an unset variable from an empty one, hence `none`.
- Secrets: `DOCKER_USERNAME`, `DOCKER_PAT` (Read scope), `COPILOT_GITHUB_TOKEN` (fine-grained PAT, Copilot Requests permission only, personal account).

## The seeded bug

The case-sensitive email uniqueness bug in `RegistrationService` is review material, not a defect to fix. Keep `register()` free of normalization, keep the schema's plain `TEXT NOT NULL UNIQUE`, and keep `RegistrationServiceIT` at its two tests. A pull request that fixes it should be praised by the reviewer; that is a demo scenario.

## Status

Not yet run on GitHub. The scripts and their tests, lint, and the sample app were verified locally. Open items for the first live run: that `sbx create --clone` carries `pr-base` and `pr-head`, that `sbx exec` starts in the clone, review duration and Copilot cost, and how the sanitized review renders. Report only what was actually verified.
