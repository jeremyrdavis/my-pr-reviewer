# AI pull-request reviewer in a Docker Sandbox

When a pull request is opened, a Copilot agent reviews it **inside a Docker Sandbox microVM** and posts its findings as one sticky comment. The agent reads the diff, checks it against `REQUIREMENTS.md`, runs the project's tests on the pull request's code, and writes a review. It never gets a token that can write to the repository.

This is the sibling of the "explorer" demo (an agent that finds a bug and proposes a fix). Same building blocks, different output: a review comment instead of a draft PR.

```
pull_request_target ──► prepare ──► review ──► comment
(or workflow_dispatch)  decide      agent in    sanitize, then create or
                        (gates)     microVM     update ONE bot comment
```

| Job | Token | What it does |
| :-- | :-- | :-- |
| `prepare` | `contents: read`, `pull-requests: read` | Decides whether to review (kill switch, bots, drafts, size, trust mode). Runs only trusted code. |
| `review` | `contents: read` | Checks out the trusted scripts and the pull request (separately), starts a Docker Sandbox with a clone of the pull request, runs the agent, and copies out one file, `REVIEW.md`. |
| `comment` | `pull-requests: write` | Sanitizes the review and creates or updates a single comment owned by the Actions bot. Runs no agent. |

## Why it is safe to run on pull requests from strangers

The workflow uses `pull_request_target`, so pull requests from forks can use the repository's secrets. That is only safe because of how the work is split.

| Risk | Control |
| :-- | :-- |
| The pull request's code runs on the runner | It never does. It is checked out into `./pr` and only handed to `sbx create --clone`, so it runs only in the microVM. Scripts, prompt and actions always come from the base branch. |
| Secrets stolen by the pull request's code | No secret is inside the sandbox. The Copilot token lives in sbx's host-side proxy (the sandbox sees a placeholder), and the Docker token stays on the runner. The Copilot token only has the Copilot Requests permission. |
| Prompt injection in the diff, title or description | The output is advisory text only. The agent job has a read-only token. The prompt marks pull request text as untrusted, and the comment is sanitized before it is posted. |
| Abusive or spammy comment text | `sanitize.sh` caps the length, breaks `@mentions`, escapes HTML comments so the marker can't be forged, and removes images. Only comments owned by `github-actions[bot]` that start with the marker are ever edited. |
| Quota burn | Per-PR concurrency (a new push cancels the old review), a 20 minute agent timeout, a size cap, draft and bot skips, a kill switch, and a trust mode. Code in the sandbox could still call Copilot with the injected token until the timeout. |
| Shell injection from pull request text | Title, body and branch names reach scripts only through `env:`, never inside `run:`. `resolve-pr.sh` validates identifiers and single-lines free text. |

## Setup

1. **Secrets** (`gh secret set <NAME>`):
   - `DOCKER_USERNAME`, `DOCKER_PAT`: a Docker Hub account and a token with at least **Read** scope. sbx needs these to start.
   - `COPILOT_GITHUB_TOKEN`: a fine-grained PAT owned by a personal account with the **Copilot Requests** permission and nothing else. The account needs Copilot. Classic `ghp_` tokens don't work with Copilot CLI.
2. **Label:** `gh label create ai-review --description "Request an AI review"`.
3. **Repository variables** (all optional, in Settings → Secrets and variables → Actions → Variables):

   | Variable | Values | Effect |
   | :-- | :-- | :-- |
   | `AI_REVIEW_ENABLED` | `false` | Kill switch: nothing is reviewed. |
   | `AI_REVIEW_TRUST` | `everyone` (default) or `trusted` | `trusted` reviews owners, members and collaborators automatically; other authors wait for a maintainer to add the `ai-review` label. |
   | `AI_REVIEW_TEST_COMMAND` | a command, or `none` | What the reviewer runs. Default `./scripts/test-in-docker.sh`. `none` means read-only review. |

4. `pull_request_target` only uses the workflow on the **default branch**, so merge it there before expecting automatic reviews.

### Who can trigger a review

By default **everyone**: any pull request from anyone, including forks, is reviewed automatically. That spends your Copilot and Docker quota and lets strangers put text in front of the agent. The controls above bound the damage, but on a busy public repository you probably want `AI_REVIEW_TRUST=trusted`. Changing it needs no code change. A new push to a pull request that needed the label needs the label again, so a maintainer re-approves new code.

## How to use it

- **Automatic:** open or update a pull request. Draft pull requests wait until they are ready for review.
- **Re-review on demand:** add (or re-add) the `ai-review` label.
- **Manual:** `gh workflow run pr-review.yml -f pr-number=<number>`. Use this to try it on an existing pull request, or to review pull requests opened by `GITHUB_TOKEN` (GitHub doesn't start workflows for those).
- **Result:** one comment titled "AI review (advisory)" with Summary, Risk, Findings, Tests and Notes. It is edited in place on every push. It never approves or blocks the pull request.

## The sample app (review material)

The repository includes a small Java registration service, copied from the explorer demo, so there is real code to review. `REQUIREMENTS.md` says email addresses are case-insensitive, but the code is case-sensitive: a **seeded bug**. A pull request that fixes it should be praised, and one that touches email handling without fixing it should be questioned. Don't fix it on the default branch; it is the demo's test material.

```bash
./scripts/test-in-docker.sh      # runs the app's tests; Docker is the only prerequisite
```

## Tests for the workflow's own scripts

None of the following needs sbx, Docker, or network access:

```bash
./tests/run.sh
```

They cover the gates, the sanitizer, the sticky-comment logic (using a fake `gh`), the prompt builder, the git preparation (a fork whose history lacks the base commit), and the agent script (using a fake `sbx`). Lint with `shellcheck -x -P SCRIPTDIR`, `actionlint`, and `yamllint`.

## Governed Docker accounts

If the Docker account behind `DOCKER_USERNAME` belongs to an organization with Docker Sandboxes governance:

- **Network:** only organization allow rules grant access. The `network-preset` and `allowed-hosts` inputs are ignored (the action prints a notice), but local deny rules still apply. The organization's policy must allow the hosts in `pr-review.yml`, or image pulls, Maven and Copilot calls fail. Policies can be scoped to teams.
- **Filesystem:** organization rules control which host paths a sandbox may mount. The action mounts only the pull request's checkout (clone mode), under the runner's home directory, so a rule like `~/**` should be enough. A denied mount shows as `403 Forbidden: mount policy denied`. List the rules with `sbx policy ls --wide`.

## Runner requirements

KVM (`/dev/kvm`), passwordless sudo, Docker Engine and Ubuntu 24.04 or later. Nested virtualization on GitHub-hosted runners isn't officially guaranteed: run `kvm-probe.yml` first. Pin sbx with the `sbx-version` input of the `sbx-agent` action, because sbx releases often.

## Status and open items

**Not yet run on GitHub.** What was verified: the scripts and their tests (the fake `sbx` and `gh` stand in for the real ones), lint, and the sample app's tests. What was seen working earlier, in the explorer demo on a hosted runner: sbx install, daemon start, login, the template pull, Copilot running through `sbx exec` with a PAT-backed secret, and a governed Docker account. To confirm on the first live run:

- that `sbx create --clone` carries the `pr-base` and `pr-head` branches into the sandbox, and that `sbx exec` starts in the clone
- how long a review plus the tests takes, and how many Copilot credits it uses
- that the sanitized review renders well in a comment

## Moving this folder into its own repository

This project was built in a subdirectory and is laid out like a repository root, with every path relative to it:

```bash
cp -r pr-reviewer ../my-pr-reviewer && cd ../my-pr-reviewer
git init -b main && git add -A && git commit -m "Initial commit"
gh repo create my-pr-reviewer --public --source=. --push
```

Then add the secrets, the label and (optionally) the variables above in the new repository.

## Credits

Built from the sbx composite action in the companion "explorer" demo. Blog post: [Running AI agents in GitHub Actions with Docker Sandboxes](https://www.docker.com/blog/running-ai-agents-in-github-actions-with-docker-sandboxes/) by Oleg Šelajev.
