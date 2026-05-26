#!/usr/bin/env bash
# Smoke test the built image: server starts, GUI responds, a repacked
# linux/amd64 client process makes contact with the server.
#
# Inputs:
#   IMAGE       full image ref (e.g. velociraptor:smoke). Required.
#   WORKDIR     host directory to mount as /velociraptor. Defaults to a temp dir.
#   CLIENT_ARCH        amd64 or arm64. Must match the runner container's arch
#                      (default amd64 for GitHub Actions runners).
#   READY_TIMEOUT_S    how long to wait for the server to be ready (default 120)
#   CLIENT_TIMEOUT_S   how long to wait for client/server traffic (default 90)
set -euo pipefail

IMAGE="${IMAGE:?IMAGE env var required}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
CLIENT_ARCH="${CLIENT_ARCH:-amd64}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-120}"
CLIENT_TIMEOUT_S="${CLIENT_TIMEOUT_S:-90}"

case "$CLIENT_ARCH" in
  amd64|arm64) ;;
  *) echo "CLIENT_ARCH must be amd64 or arm64 (got: $CLIENT_ARCH)" >&2; exit 2 ;;
esac

NET="velo-smoke-$$"
SERVER="velo-server-$$"
CLIENT="velo-client-$$"

cleanup() {
  rc=$?
  echo "--- Cleanup (rc=$rc) ---"
  if [ $rc -ne 0 ]; then
    echo "::group::server logs"
    docker logs "$SERVER" 2>&1 || true
    echo "::endgroup::"
    echo "::group::client logs"
    docker logs "$CLIENT" 2>&1 || true
    echo "::endgroup::"
  fi
  docker rm -f "$SERVER" "$CLIENT" 2>/dev/null || true
  docker network rm "$NET" 2>/dev/null || true
  exit $rc
}
trap cleanup EXIT

echo "--- Network ---"
docker network create "$NET" >/dev/null

echo "--- Start server ($SERVER) ---"
mkdir -p "$WORKDIR"
docker run -d --rm \
  --name "$SERVER" \
  --network "$NET" \
  --network-alias velociraptor \
  -e VELOX_DEFAULT_USER=admin \
  -e VELOX_DEFAULT_PASSWORD=smoketest \
  -e VELOX_FRONTEND_HOSTNAME=velociraptor \
  -e VELOX_FRONTEND_SERVER_SCHEME=https \
  -v "$WORKDIR:/velociraptor" \
  "$IMAGE" >/dev/null

echo "--- Wait for server ready (timeout=${READY_TIMEOUT_S}s) ---"
deadline=$(( $(date +%s) + READY_TIMEOUT_S ))
ready=false
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! docker inspect -f '{{.State.Running}}' "$SERVER" 2>/dev/null | grep -q true; then
    echo "Server container exited unexpectedly."
    exit 1
  fi
  if docker logs "$SERVER" 2>&1 | grep -qE "Frontend is ready to handle (client )?TLS requests"; then
    ready=true
    break
  fi
  sleep 2
done
$ready || { echo "Server did not become ready within ${READY_TIMEOUT_S}s."; exit 1; }
echo "Server reports frontend ready."

echo "--- Probe GUI port (unauthenticated, expect 401) ---"
gui_code="$(docker run --rm --network "$NET" curlimages/curl:latest \
  -ksS --max-time 10 -o /dev/null -w '%{http_code}' \
  "https://velociraptor:8889/app/index.html" || true)"
echo "  GUI HTTP code: ${gui_code}"
case "$gui_code" in
  401|403) ;;  # auth-protected (expected)
  *) echo "Expected GUI to require auth (401/403), got: ${gui_code}"; exit 1 ;;
esac

echo "--- Authenticate to GUI with default credentials (expect 200) ---"
auth_code="$(docker run --rm --network "$NET" curlimages/curl:latest \
  -ksS --max-time 10 -u "admin:smoketest" -o /dev/null -w '%{http_code}' \
  "https://velociraptor:8889/app/index.html" || true)"
echo "  Authenticated HTTP code: ${auth_code}"
if [ "$auth_code" != "200" ]; then
  echo "Authentication with default credentials failed (got: ${auth_code})"
  exit 1
fi

echo "--- Locate repacked linux/${CLIENT_ARCH} client ---"
CLIENT_BIN_HOST="$WORKDIR/client_bundles/linux/velociraptor_client_${CLIENT_ARCH}_repacked"
for _ in $(seq 1 20); do
  [ -s "$CLIENT_BIN_HOST" ] && break
  sleep 2
done
if [ ! -s "$CLIENT_BIN_HOST" ]; then
  echo "Repacked client binary not found at $CLIENT_BIN_HOST"
  ls -la "$WORKDIR/client_bundles/linux" || true
  exit 1
fi

echo "--- Start client ($CLIENT) ---"
docker run -d --rm \
  --name "$CLIENT" \
  --platform "linux/${CLIENT_ARCH}" \
  --network "$NET" \
  -v "$WORKDIR/client_bundles/linux:/client:ro" \
  ubuntu:26.04 \
  "/client/velociraptor_client_${CLIENT_ARCH}_repacked" client -v >/dev/null

echo "--- Wait for client/server contact (timeout=${CLIENT_TIMEOUT_S}s) ---"
deadline=$(( $(date +%s) + CLIENT_TIMEOUT_S ))
contact=false
# Patterns Velociraptor uses around enrollment / client check-in.
pattern='Enrolling|Enrolled|client_id|Foreman|Receive client'
while [ "$(date +%s)" -lt "$deadline" ]; do
  if docker logs "$SERVER" 2>&1 | grep -qE "$pattern"; then
    contact=true
    break
  fi
  if docker logs "$CLIENT" 2>&1 | grep -qE "Enrolling|Sending.*to server|Connected to server"; then
    contact=true
    break
  fi
  sleep 3
done

if ! $contact; then
  echo "No client/server contact observed within ${CLIENT_TIMEOUT_S}s."
  exit 1
fi

echo "--- Image validation PASSED ---"
