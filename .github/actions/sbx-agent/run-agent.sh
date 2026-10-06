#!/usr/bin/env bash
# Runs the Copilot agent inside a Docker Sandbox (sbx) microVM and copies ONE result
# file out of it. The agent works in a git clone inside the sandbox and never gets a
# write token. Only the named result file leaves the sandbox, as text.
#
# Inputs (environment): DOCKER_USERNAME, DOCKER_PAT, COPILOT_TOKEN, PROMPT_FILE,
# RESULT_PATH, and optionally WORKSPACE, OUT_DIR, NETWORK_PRESET, ALLOWED_HOSTS,
# AGENT_TIMEOUT_MINUTES.
#   PROMPT_FILE  absolute, or relative to $GITHUB_WORKSPACE
#   WORKSPACE    directory cloned into the sandbox; absolute, or relative to
#                $GITHUB_WORKSPACE (default: $GITHUB_WORKSPACE)
#   RESULT_PATH  file the agent writes, relative to the sandbox workspace
# Outputs: $OUT_DIR/result.md, $OUT_DIR/agent.log, and `has-result`, `result-file`,
# `output-dir` in $GITHUB_OUTPUT.
set -euo pipefail

# A secret that doesn't exist reaches this script as an empty string, so say which input.
missing=0
for pair in "docker-username:DOCKER_USERNAME" "docker-pat:DOCKER_PAT" "copilot-token:COPILOT_TOKEN" "prompt-file:PROMPT_FILE" "result-path:RESULT_PATH"; do
  input="${pair%%:*}"
  var="${pair##*:}"
  if [[ -z "${!var:-}" ]]; then
    echo "::error::The '${input}' input is empty. If it comes from a secret, check that the secret exists in this repository and that the name in the workflow matches."
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || exit 1

OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-/tmp}/sbx-agent-out}"
NETWORK_PRESET="${NETWORK_PRESET:-balanced}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}"
AGENT_TIMEOUT_MINUTES="${AGENT_TIMEOUT_MINUTES:-20}"
TEMPLATE_IMAGE="docker/sandbox-templates:copilot"
SANDBOX="ci-agent-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
MAX_RESULT_BYTES=200000

if [[ ! "${AGENT_TIMEOUT_MINUTES}" =~ ^[0-9]+$ ]]; then
  echo "::error::agent-timeout-minutes must be a whole number"
  exit 1
fi
case "${NETWORK_PRESET}" in
  allow-all | balanced | deny-all) ;;
  *)
    echo "::error::network-preset must be allow-all, balanced or deny-all"
    exit 1
    ;;
esac
# The result path is used inside the sandbox: keep it a plain relative path.
if [[ ! "${RESULT_PATH}" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ || "/${RESULT_PATH}/" == *"/../"* ]]; then
  echo "::error::result-path must be a simple relative path without '..'"
  exit 1
fi

root="${GITHUB_WORKSPACE:?}"
[[ "${PROMPT_FILE}" == /* ]] || PROMPT_FILE="${root}/${PROMPT_FILE}"
WORKSPACE="${WORKSPACE:-${root}}"
[[ "${WORKSPACE}" == /* ]] || WORKSPACE="${root}/${WORKSPACE}"
[[ -f "${PROMPT_FILE}" ]] || { echo "::error::Prompt file not found: ${PROMPT_FILE}"; exit 1; }
[[ -d "${WORKSPACE}" ]] || { echo "::error::Workspace not found: ${WORKSPACE}"; exit 1; }
mkdir -p "${OUT_DIR}"

set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}
set_output has-result false
set_output result-file "${OUT_DIR}/result.md"
set_output output-dir "${OUT_DIR}"

cleanup() {
  set +e
  echo "::group::sbx diagnostics"
  sbx ls
  sbx policy ls
  sbx policy log
  echo "::endgroup::"
  sbx rm --force "${SANDBOX}" > /dev/null 2>&1
}
trap cleanup EXIT

echo "::group::Start the sbx daemon"
nohup sbx daemon start > "${OUT_DIR}/sbx-daemon.log" 2>&1 &
running=false
for _ in $(seq 1 30); do
  # Capture first: with pipefail, `grep -q` closing the pipe early can fail the pipeline.
  daemon_status="$(sbx daemon status 2> /dev/null || true)"
  if grep -q -i running <<< "${daemon_status}"; then
    running=true
    break
  fi
  sleep 1
done
if [[ "${running}" != "true" ]]; then
  echo "::error::sbx daemon did not start within 30 seconds"
  cat "${OUT_DIR}/sbx-daemon.log" >&2 || true
  exit 1
fi
echo "::endgroup::"

echo "::group::Authenticate with Docker Hub"
printf '%s' "${DOCKER_PAT}" | sbx login --username "${DOCKER_USERNAME}" --password-stdin
# Pre-pull the sandbox template with the runner's Docker, using a throwaway config dir.
(
  DOCKER_CONFIG="$(mktemp -d)"
  export DOCKER_CONFIG
  trap 'rm -rf "${DOCKER_CONFIG}"' EXIT
  printf '%s' "${DOCKER_PAT}" | docker login --username "${DOCKER_USERNAME}" --password-stdin
  docker pull "${TEMPLATE_IMAGE}"
) || echo "::warning::Could not pre-pull ${TEMPLATE_IMAGE}; sbx will pull it when the sandbox is created"
echo "::endgroup::"

echo "::group::Network policy"
# With organization governance, org rules decide what is reachable and local allow
# rules are inactive. Without it, the preset plus the allowed hosts apply.
sbx policy init "${NETWORK_PRESET}"
hosts="$(printf '%s' "${ALLOWED_HOSTS}" | tr -s ' \n,' ',' | sed -e 's/^,//' -e 's/,$//')"
if [[ -n "${hosts}" ]]; then
  # Under organization governance sbx refuses local allow rules. That is expected, not a
  # failure: the organization's policy already decides what the sandbox can reach.
  if allow_output="$(sbx policy allow network "${hosts}" 2>&1)"; then
    echo "${allow_output}"
  elif grep -q -i 'managed by your organization' <<< "${allow_output}"; then
    echo "::notice::Network policy is managed by your Docker organization; the allowed-hosts input was not applied. Make sure the organization's policy allows these hosts: ${hosts}"
  else
    echo "${allow_output}" >&2
    exit 1
  fi
fi
echo "::endgroup::"

echo "::group::Store the Copilot token as an sbx secret"
# The host-side proxy injects this into requests to GitHub and Copilot endpoints.
# The sandbox itself only ever sees a placeholder.
sbx secret set github -t "${COPILOT_TOKEN}"
echo "::endgroup::"

echo "::group::Create the sandbox"
# --clone: the agent works in a separate git clone inside the sandbox, never the runner's tree.
sbx create --clone --name "${SANDBOX}" copilot "${WORKSPACE}" <<< "y"
echo "::endgroup::"

echo "::group::Run the agent"
prompt="$(cat "${PROMPT_FILE}")"
set +e
timeout --signal=TERM --kill-after=30 "${AGENT_TIMEOUT_MINUTES}m" \
  sbx exec "${SANDBOX}" copilot --yolo -p "${prompt}" 2>&1 | tee "${OUT_DIR}/agent.log"
agent_rc="${PIPESTATUS[0]}"
set -e
echo "::endgroup::"
if [[ "${agent_rc}" -ne 0 ]]; then
  echo "::error::The agent exited with code ${agent_rc} (124 means it hit the ${AGENT_TIMEOUT_MINUTES} minute timeout)"
  exit "${agent_rc}"
fi

echo "::group::Copy the result out of the sandbox"
# The file travels as base64 between random markers, which keeps it intact even if sbx
# prints extra lines around the command output. It is capped in size inside the sandbox.
marker="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
read -r -d '' extract_script <<'EOF' || true
set -euo pipefail
file="$1"; marker="$2"; max="$3"
echo "BEGIN-${marker}"
if [ -f "${file}" ] && [ ! -L "${file}" ]; then head -c "${max}" -- "${file}" | base64 -w0; fi
echo
echo "END-${marker}"
EOF
sbx exec "${SANDBOX}" bash -c "${extract_script}" _ "${RESULT_PATH}" "${marker}" "${MAX_RESULT_BYTES}" > "${OUT_DIR}/extract.raw"
sed -n "/^BEGIN-${marker}\$/,/^END-${marker}\$/p" "${OUT_DIR}/extract.raw" \
  | sed -e '1d' -e '$d' | tr -d '\n' | base64 -d > "${OUT_DIR}/result.md"
rm -f "${OUT_DIR}/extract.raw"
echo "::endgroup::"

if [[ -s "${OUT_DIR}/result.md" ]]; then
  echo "Copied ${RESULT_PATH} ($(wc -c < "${OUT_DIR}/result.md") bytes)."
  set_output has-result true
else
  echo "::warning::The agent finished but did not write ${RESULT_PATH}."
fi
