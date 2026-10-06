#!/usr/bin/env bash
# Installs Docker Sandboxes (sbx) from Docker's apt repository on an Ubuntu runner.
set -euo pipefail

if [[ ! -e /dev/kvm ]]; then
  echo "::error::/dev/kvm is missing. Docker Sandboxes run in a microVM and need KVM. Run the 'KVM probe' workflow, or use a self-hosted runner with KVM."
  exit 1
fi

echo "::group::Install docker-sbx"
# Adds Docker's apt repo without installing Docker Engine (already on the runner).
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
if [[ -n "${SBX_VERSION:-}" ]]; then
  sudo apt-get install -y "docker-sbx=${SBX_VERSION}"
else
  sudo apt-get install -y docker-sbx
fi
sbx version
# Let the runner user create microVMs.
sudo chmod 666 /dev/kvm
echo "::endgroup::"
