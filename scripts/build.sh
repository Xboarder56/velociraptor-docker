#!/usr/bin/env bash
# Build the image locally from the pinned lockfiles.
#   scripts/build.sh [TAG] [extra docker build args...]
# Example: scripts/build.sh velociraptor:local --platform linux/amd64
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:-velociraptor:local}"
shift || true
args=()
while IFS= read -r line; do
  args+=(--build-arg "$line")
done < <(scripts/build-args.sh)
args+=(--build-arg "GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)")
exec docker build "${args[@]}" -t "$tag" "$@" .
