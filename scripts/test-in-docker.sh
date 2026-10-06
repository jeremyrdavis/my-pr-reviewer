#!/usr/bin/env bash
# Runs Maven in a pinned container against the local Docker daemon.
# Docker is the only prerequisite. Extra arguments are passed to Maven before the goal:
#   ./scripts/test-in-docker.sh -Dtest=RegistrationServiceIT#rejectsExactDuplicate
set -euo pipefail

MAVEN_IMAGE="maven:3.9.9-eclipse-temurin-21@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Testcontainers inside the Maven container talks to the local daemon through the
# mounted socket (inside a Docker Sandbox, that is the sandbox's private daemon).
# PostgreSQL starts as a sibling container, so Maven reaches it via the host gateway.
exec docker run --rm \
  -v "${repo_root}:/workspace" \
  -w /workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v registration-demo-m2:/root/.m2 \
  --add-host=host.testcontainers.internal:host-gateway \
  -e TESTCONTAINERS_HOST_OVERRIDE=host.testcontainers.internal \
  "${MAVEN_IMAGE}" \
  mvn --batch-mode "$@" test
