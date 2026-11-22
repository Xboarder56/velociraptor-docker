#!/usr/bin/env bash
# Print the image build arguments (KEY=VALUE, one per line) from
# versions.env, binaries.lock and artifacts.lock. Used by CI and by
# scripts/build.sh so local builds use exactly the pinned, verified inputs.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. ./versions.env
# shellcheck disable=SC1091
. ./binaries.lock
# shellcheck disable=SC1091
. ./artifacts.lock

echo "VELOX_VERSION=${VELOX_VERSION}"
for key in LINUX_AMD64 LINUX_ARM64 LINUX_AMD64_MUSL DARWIN_AMD64 DARWIN_ARM64 WINDOWS_EXE WINDOWS_MSI; do
  version_var="${key}_VERSION" url_var="${key}_URL" sha_var="${key}_SHA256"
  echo "VELOX_VERSION_${key}=${!version_var}"
  echo "VELOX_URL_${key}=${!url_var}"
  echo "VELOX_SHA256_${key}=${!sha_var}"
done
echo "TRIAGE_SOURCE_COMMIT=${TRIAGE_SOURCE_COMMIT}"
echo "TRIAGE_LINUX_UAC_URL=${TRIAGE_LINUX_UAC_URL}"
echo "TRIAGE_LINUX_UAC_SHA256=${TRIAGE_LINUX_UAC_SHA256}"
echo "TRIAGE_WINDOWS_TARGETS_URL=${TRIAGE_WINDOWS_TARGETS_URL}"
echo "TRIAGE_WINDOWS_TARGETS_SHA256=${TRIAGE_WINDOWS_TARGETS_SHA256}"
echo "BASE_IMAGE=$(awk '/^FROM /{print $2; exit}' Dockerfile)"
