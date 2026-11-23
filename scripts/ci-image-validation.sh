#!/usr/bin/env bash
# End-to-end validation of a built image:
#   * server starts as the unprivileged user, config is private, healthcheck
#     turns healthy, GUI and the GUI's own API work with the bootstrap login
#   * bundled Triage artifacts and an operator-supplied artifact are loaded
#     by the running server
#   * every client bundle and the .deb/.rpm packages are produced
#   * a repacked client enrolls, and a collection runs on it to completion
#
# Inputs:
#   IMAGE              full image ref (e.g. velociraptor:smoke). Required.
#   WORKDIR            host directory to mount as /velociraptor. Defaults to a temp dir.
#   CLIENT_ARCH        amd64 or arm64: the runner's architecture (default: detected).
#   READY_TIMEOUT_S    how long to wait for the server to be ready (default 180)
#   CLIENT_TIMEOUT_S   how long to wait for enrollment / the collection (default 180)
#   CONTAINER_RUNTIME  set to "podman" when `docker` is Podman (auto-detected otherwise)
set -euo pipefail

IMAGE="${IMAGE:?IMAGE env var required}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
case "$(uname -m)" in
  x86_64|amd64) detected_arch=amd64 ;;
  aarch64|arm64) detected_arch=arm64 ;;
  *) detected_arch=unknown ;;
esac
CLIENT_ARCH="${CLIENT_ARCH:-$detected_arch}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-180}"
CLIENT_TIMEOUT_S="${CLIENT_TIMEOUT_S:-180}"
PASSWORD="smoke-test-password"
# Helper images, fully qualified (Podman does not guess registries) and pinned
# by digest (Dependabot does not track these; bump by hand).
UBUNTU_IMAGE="docker.io/library/ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db"
ALPINE_IMAGE="docker.io/library/alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"
FEDORA_IMAGE="docker.io/library/fedora:43@sha256:f01112b9a1f1d0504ad962d9adfa401425033f8ab067e0a821904ebdde5b8ca5"

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
  docker rm -f "$SERVER" "$CLIENT" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  exit $rc
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# PID of the Velociraptor server process (tini is PID 1).
server_pid() {
  docker exec "$1" sh -c 'for p in /proc/[0-9]*; do
    case "$(tr "\000" " " < "$p/cmdline" 2>/dev/null)" in
      */velociraptor*" frontend"*) echo "${p#/proc/}"; exit 0 ;;
    esac
  done; exit 1'
}

# GUI / API requests are made from inside the server container (curl and jq
# are in the image), with a cookie jar for the CSRF-protected POST endpoints.
GUI="https://127.0.0.1:8889"
api_get() {
  docker exec "$SERVER" curl -ksS --max-time 20 -u "admin:$PASSWORD" \
    -c /tmp/ci.cookies -b /tmp/ci.cookies "$GUI$1"
}
api_post() {
  local path="$1" body="$2"
  docker exec "$SERVER" bash -c '
    set -euo pipefail
    gui="$1" pass="$2" path="$3" body="$4"
    auth=(-ksS --max-time 20 -u "admin:$pass" -c /tmp/ci.cookies -b /tmp/ci.cookies)
    token="$(curl "${auth[@]}" -D - -o /dev/null "$gui/app/index.html" \
      | awk -F": " "tolower(\$1)==\"x-csrf-token\" {print \$2}" | tr -d "\r")"
    curl "${auth[@]}" -X POST -H "Content-Type: application/json" \
      -H "X-CSRF-Token: $token" -H "Origin: $gui" -H "Referer: $gui/app/index.html" \
      -d "$body" "$gui$path"
  ' _ "$GUI" "$PASSWORD" "$path" "$body"
}

echo "--- Network ---"
docker network create "$NET" >/dev/null

echo "--- Prepare data directory with an operator-supplied artifact ---"
mkdir -p "$WORKDIR/artifacts"
# The container hands the directory to its server user; keep it traversable
# so this script can read the client bundles afterwards.
chmod 0755 "$WORKDIR" "$WORKDIR/artifacts"
cat > "$WORKDIR/artifacts/ci-extra.yaml" <<'EOF'
name: CI.Extra.Artifact
description: Loaded from VELOX_EXTRA_ARTIFACTS_DIR by the CI smoke test.
sources:
  - query: SELECT 1 AS One FROM scope()
EOF
chmod 0644 "$WORKDIR/artifacts/ci-extra.yaml"

# Podman ignores HEALTHCHECK in OCI-format images; declare it as compose does.
HEALTH_ARGS=()
# (Through a `docker` shim podman calls itself "docker version", so also
# honour CONTAINER_RUNTIME=podman and check `docker version`.)
if [ "${CONTAINER_RUNTIME:-}" = podman ] || docker version 2>/dev/null | grep -qi podman; then
  HEALTH_ARGS=(--health-cmd /usr/local/bin/velox-healthcheck --health-interval 10s --health-start-period 120s)
  echo "  (Podman: passing the healthcheck explicitly)"
fi

echo "--- Start server ($SERVER) ---"
docker run -d ${HEALTH_ARGS[@]+"${HEALTH_ARGS[@]}"} \
  --name "$SERVER" \
  --network "$NET" \
  --network-alias velociraptor \
  -e VELOX_DEFAULT_USER=admin \
  -e VELOX_DEFAULT_PASSWORD="$PASSWORD" \
  -e VELOX_FRONTEND_HOSTNAME=velociraptor \
  -e VELOX_FRONTEND_SERVER_SCHEME=https \
  -e VELOX_START_SERVER_VERBOSE=false \
  -v "$WORKDIR:/velociraptor" \
  "$IMAGE" >/dev/null

echo "--- Wait for server ready (timeout=${READY_TIMEOUT_S}s) ---"
deadline=$(( $(date +%s) + READY_TIMEOUT_S ))
ready=false
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER" 2>/dev/null)" != "true" ]; then
    fail "server container exited unexpectedly"
  fi
  code="$(docker exec "$SERVER" curl -ks --max-time 3 -o /dev/null -w '%{http_code}' "$GUI/" 2>/dev/null || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    ready=true
    break
  fi
  sleep 2
done
$ready || fail "server did not become ready within ${READY_TIMEOUT_S}s"
echo "  GUI is serving."

echo "--- Server runs unprivileged and the config is private ---"
pid="$(server_pid "$SERVER")" || fail "no Velociraptor server process found"
server_uid="$(docker exec "$SERVER" awk '/^Uid:/ {print $2}' "/proc/$pid/status")"
[ "$server_uid" = "10001" ] || fail "server runs as uid $server_uid, expected 10001"
config_mode="$(docker exec "$SERVER" stat -c '%a %u' /velociraptor/server.config.yaml)"
[ "$config_mode" = "600 10001" ] || fail "server.config.yaml is '$config_mode', expected '600 10001'"
echo "  uid 10001, server.config.yaml 0600"

echo "--- Unauthenticated GUI is refused ---"
code="$(docker run --rm --network "$NET" --entrypoint curl "$IMAGE" \
  -ksS --max-time 10 -o /dev/null -w '%{http_code}' https://velociraptor:8889/app/index.html || true)"
case "$code" in
  401|403) echo "  HTTP $code" ;;
  *) fail "expected the GUI to require auth (401/403), got: $code" ;;
esac

echo "--- Bootstrap login works for the GUI and the GUI's API ---"
code="$(docker exec "$SERVER" curl -ks -u "admin:$PASSWORD" -o /dev/null -w '%{http_code}' "$GUI/app/index.html")"
[ "$code" = 200 ] || fail "authenticated GUI request returned $code"
traits="$(api_get /api/v1/GetUserUITraits)"
[ "$(jq -r '.user_type // empty' <<< "$traits")" = "USER_TYPE_ADMIN" ] || \
  fail "GetUserUITraits did not return an admin user: ${traits:0:300}"
echo "  GUI 200, API user_type USER_TYPE_ADMIN"

echo "--- Bundled and operator-supplied artifacts are loaded by the server ---"
for artifact in \
  Linux.Triage.UAC Windows.Triage.Targets \
  Windows.Hayabusa.Rules Windows.Hayabusa.Monitoring \
  Windows.Sigma.Triage Windows.Sigma.BaseVQL Windows.Sigma.Base Windows.Sigma.BaseEvents \
  Linux.Sigma.Triage Linux.Sigma.Base MacOS.Sigma.Triage MacOS.Sigma.BaseVQL \
  CI.Extra.Artifact
do
  body="$(api_get "/api/v1/GetArtifactFile?name=${artifact}" | jq -r '.artifact // empty')"
  # Unknown names return a generic template; known ones a "Custom." copy.
  [[ "$body" == "name: Custom.${artifact}"$'\n'* ]] || fail "server has no artifact $artifact"
  echo "  Found $artifact"
done

echo "--- Container healthcheck turns healthy ---"
health=""
for _ in $(seq 1 30); do
  if [ "${#HEALTH_ARGS[@]}" -gt 0 ]; then
    # Podman runs healthchecks from systemd timers, which CI runners (no
    # user session) lack: run the configured check directly.
    if docker healthcheck run "$SERVER" >/dev/null 2>&1; then health=healthy; fi
  else
    health="$(docker inspect -f '{{.State.Health.Status}}' "$SERVER")"
  fi
  [ "$health" = healthy ] && break
  sleep 5
done
[ "$health" = healthy ] || fail "healthcheck status is '$health'"
echo "  healthy"

echo "--- Every client bundle was produced ---"
BUNDLES="$WORKDIR/client_bundles"
for f in \
  linux/velociraptor_client_amd64_repacked \
  linux/velociraptor_client_arm64_repacked \
  linux/velociraptor_client_amd64_musl_repacked \
  linux/velociraptor_client_amd64.deb linux/velociraptor_client_amd64.rpm \
  linux/velociraptor_client_arm64.deb linux/velociraptor_client_arm64.rpm \
  mac/velociraptor_client_amd64_repacked mac/velociraptor_client_arm64_repacked \
  windows/velociraptor_client_repacked.exe windows/velociraptor_client_repacked.msi
do
  [ -s "$BUNDLES/$f" ] || { ls -laR "$BUNDLES" || true; fail "missing client bundle $f"; }
done
# Repacked binaries must carry the config, i.e. differ from the originals.
for pair in \
  "mac/velociraptor_client_amd64_repacked|/opt/velociraptor/mac/velociraptor_client_amd64" \
  "mac/velociraptor_client_arm64_repacked|/opt/velociraptor/mac/velociraptor_client_arm64" \
  "windows/velociraptor_client_repacked.exe|/opt/velociraptor/windows/velociraptor_client.exe" \
  "windows/velociraptor_client_repacked.msi|/opt/velociraptor/windows/velociraptor_client.msi"
do
  IFS='|' read -r out src <<< "$pair"
  repacked_sha="$(sha256sum "$BUNDLES/$out" | awk '{print $1}')"
  original_sha="$(docker exec "$SERVER" sha256sum "$src" | awk '{print $1}')"
  [ "$repacked_sha" != "$original_sha" ] || fail "$out is identical to the unconfigured binary"
done
echo "  all 11 bundles present; repacked binaries differ from the originals"

echo "--- Linux packages install and carry the server URL (${CLIENT_ARCH}) ---"
# The post-install scripts try to start a service, which fails without an
# init system; the installed files are what matter here.
docker run --rm -v "$BUNDLES/linux:/pkg:ro" "$UBUNTU_IMAGE" bash -c "
  dpkg -i /pkg/velociraptor_client_${CLIENT_ARCH}.deb >/dev/null 2>&1 || true
  test -x /usr/local/bin/velociraptor_client
  grep -q 'https://velociraptor:8000/' /etc/velociraptor/client.config.yaml"
echo "  .deb OK"
docker run --rm -v "$BUNDLES/linux:/pkg:ro" "$FEDORA_IMAGE" bash -c "
  rpm -i /pkg/velociraptor_client_${CLIENT_ARCH}.rpm >/dev/null 2>&1 || true
  rpm -q velociraptor_client >/dev/null
  test -x /usr/local/bin/velociraptor_client
  grep -q 'https://velociraptor:8000/' /etc/velociraptor/client.config.yaml"
echo "  .rpm OK"

if [ "$CLIENT_ARCH" = amd64 ]; then
  echo "--- Repacked static musl client runs on a non-glibc host (Alpine) ---"
  docker run --rm -v "$BUNDLES/linux:/client:ro" "$ALPINE_IMAGE" \
    /client/velociraptor_client_amd64_musl_repacked version >/dev/null
  docker run --rm -v "$BUNDLES/linux:/client:ro" "$ALPINE_IMAGE" \
    /client/velociraptor_client_amd64_musl_repacked config show >/dev/null
  echo "  musl client runs and carries an embedded config"
fi

echo "--- Start client ($CLIENT) ---"
docker run -d \
  --name "$CLIENT" \
  --network "$NET" \
  -v "$BUNDLES/linux:/client:ro" \
  "$UBUNTU_IMAGE" \
  "/client/velociraptor_client_${CLIENT_ARCH}_repacked" client -v >/dev/null

echo "--- Client enrolls (timeout=${CLIENT_TIMEOUT_S}s) ---"
deadline=$(( $(date +%s) + CLIENT_TIMEOUT_S ))
client_id=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  client_id="$(api_get '/api/v1/SearchClients?query=all&limit=10' | jq -r '.items[0].client_id // empty' 2>/dev/null || true)"
  [ -n "$client_id" ] && break
  sleep 3
done
[ -n "$client_id" ] || fail "no client enrolled within ${CLIENT_TIMEOUT_S}s"
echo "  enrolled as $client_id"

echo "--- A collection runs on the client and completes ---"
flow_id="$(api_post /api/v1/CollectArtifact \
  "{\"client_id\":\"$client_id\",\"artifacts\":[\"Generic.Client.Info\"]}" | jq -r '.flow_id // empty')"
[ -n "$flow_id" ] || fail "CollectArtifact did not return a flow id"
state=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  details="$(api_get "/api/v1/GetFlowDetails?client_id=${client_id}&flow_id=${flow_id}")"
  state="$(jq -r '.context.state // empty' <<< "$details")"
  case "$state" in FINISHED|ERROR) break ;; esac
  sleep 3
done
[ "$state" = FINISHED ] || fail "flow $flow_id ended in state '${state:-<none>}'"
rows="$(jq -r '.context.total_collected_rows // 0' <<< "$details")"
[ "$rows" -gt 0 ] || fail "flow $flow_id returned no rows"
echo "  $flow_id FINISHED with $rows rows"

echo "--- Client packages are built as a server collection (GUI downloads) ---"
packages_flow=""
for _ in $(seq 1 60); do
  logs="$(docker logs "$SERVER" 2>&1)"
  if [[ "$logs" == *"[packages] WARNING"* ]]; then
    fail "package helper reported: $(grep -m1 '\[packages\] WARNING' <<< "$logs")"
  fi
  packages_flow="$(sed -n 's/^\[packages\] client packages ready: .* \(F\.[A-Z0-9]*\) .*/\1/p' <<< "$logs" | head -n1)"
  [ -n "$packages_flow" ] && break
  sleep 5
done
[ -n "$packages_flow" ] || fail "client packages were not built within 5 minutes"
uploads="$(api_get "/api/v1/GetFlowDetails?client_id=server&flow_id=${packages_flow}" | jq -r '.context.total_uploaded_files // 0')"
[ "$uploads" -ge 3 ] || fail "package collection $packages_flow uploaded only $uploads files"
echo "  $packages_flow FINISHED with $uploads uploaded files (MSI, deb, rpm)"

echo "--- Image validation PASSED ---"
