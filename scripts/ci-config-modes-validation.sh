#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-velociraptor:smoke}"
# Space-separated list of previously published images to upgrade from.
LEGACY_IMAGES="${LEGACY_IMAGES:-${LEGACY_IMAGE:-}}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-300}"
case "$(uname -m)" in
  x86_64|amd64) CLIENT_ARCH=amd64 ;;
  *) CLIENT_ARCH=arm64 ;;
esac
UBUNTU_IMAGE="ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db"
TEST_ROOT="$(mktemp -d)"
SUFFIX="$$-${RANDOM}"
ACTIVE_CONTAINERS=()
ACTIVE_NETWORKS=()

fail() {
  echo "FATAL: $*" >&2
  return 1
}

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    for container in "${ACTIVE_CONTAINERS[@]}"; do
      if docker inspect "$container" >/dev/null 2>&1; then
        echo "::group::${container} logs"
        docker logs "$container" 2>&1 || true
        echo "::endgroup::"
      fi
    done
  fi
  for container in "${ACTIVE_CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  for network in ${ACTIVE_NETWORKS[@]+"${ACTIVE_NETWORKS[@]}"}; do
    docker network rm "$network" >/dev/null 2>&1 || true
  done
  # Bind-mounted files may be root-owned on Linux CI runners. A cleanup failure
  # must not turn an otherwise successful validation into a false negative;
  # hosted runners are ephemeral.
  rm -rf "$TEST_ROOT" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

wait_ready() {
  local container="$1"
  local deadline=$(( $(date +%s) + READY_TIMEOUT_S ))
  local code
  local running

  while [ "$(date +%s)" -lt "$deadline" ]; do
    running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
    if [ "$running" != "true" ]; then
      fail "$container exited before becoming ready"
      return 1
    fi
    if code="$(docker exec "$container" curl -ksS --max-time 3 \
      -o /dev/null -w '%{http_code}' https://127.0.0.1:8889/app/index.html 2>/dev/null)"; then
      case "$code" in
        200|401|403) return 0 ;;
      esac
    fi
    sleep 2
  done

  fail "$container did not become ready within ${READY_TIMEOUT_S}s"
}

# Files written by the container belong to its server user and are private
# (the config is 0600), so read them through a throwaway container.
host_read() {
  docker run --rm --entrypoint cat -v "$(dirname "$1"):/d:ro" "$IMAGE" "/d/$(basename "$1")"
}

assert_private_config() {
  local container="$1" mode uid
  uid="$(docker exec "$container" awk '/^Uid:/ {print $2}' /proc/1/status)"
  [ "$uid" = 10001 ] || fail "$container: server runs as uid $uid, expected 10001"
  mode="$(docker exec "$container" stat -c '%a %u' /velociraptor/server.config.yaml)"
  [ "$mode" = "600 10001" ] || fail "$container: server.config.yaml is '$mode', expected '600 10001'"
}

assert_gui_api() {
  local container="$1" username="$2" password="$3" user_type
  user_type="$(docker exec "$container" curl -ksS --max-time 10 -u "$username:$password" \
    https://127.0.0.1:8889/api/v1/GetUserUITraits | jq -r '.user_type // empty')"
  [ -n "$user_type" ] || fail "$container: the GUI API did not answer for $username"
}

client_ids() {
  docker exec "$1" sh -c 'ls -1 /velociraptor/clients 2>/dev/null | grep "^C\." || true'
}

assert_log_contains() {
  local container="$1"
  local expected="$2"
  local output

  output="$(docker logs "$container" 2>&1)"
  [[ "$output" == *"$expected"* ]] || \
    fail "$container: expected logs to contain: $expected"
}

start_server_with_image() {
  local container="$1"
  local data_dir="$2"
  local image="$3"
  shift 3

  mkdir -p "$data_dir"
  ACTIVE_CONTAINERS+=("$container")
  docker run -d \
    --name "$container" \
    -v "$data_dir:/velociraptor" \
    "$@" \
    "$image" >/dev/null
  wait_ready "$container"
}

start_server() {
  local container="$1"
  local data_dir="$2"
  shift 2
  start_server_with_image "$container" "$data_dir" "$IMAGE" "$@"
}

stop_server() {
  docker rm -f "$1" >/dev/null
}

assert_config_value() {
  local container="$1"
  local config_file="$2"
  local expression="$3"
  local expected="$4"
  local actual

  actual="$(docker exec "$container" yq -r "$expression" "$config_file")"
  if [ "$actual" != "$expected" ]; then
    fail "$container: expected $expression to be '$expected', got '$actual'"
  fi
}

assert_auth() {
  local container="$1"
  local username="$2"
  local password="$3"
  local code

  code="$(docker exec "$container" curl -ksS --max-time 10 \
    -u "$username:$password" -o /dev/null -w '%{http_code}' \
    https://127.0.0.1:8889/app/index.html)"
  if [ "$code" != "200" ]; then
    fail "$container: expected authenticated GUI response 200, got $code"
  fi
}

for LEGACY in $LEGACY_IMAGES; do
  echo "--- Real upgrade from $LEGACY (data, login and client identity survive) ---"
  n="${#ACTIVE_CONTAINERS[@]}"
  UPGRADE_DATA="$TEST_ROOT/upgrade-data-$n"
  UPGRADE_NET="velo-upgrade-$SUFFIX-$n"
  UPGRADE_OLD_CONTAINER="velo-config-upgrade-old-$SUFFIX-$n"
  UPGRADE_NEW_CONTAINER="velo-config-upgrade-new-$SUFFIX-$n"
  UPGRADE_CLIENT="velo-config-upgrade-client-$SUFFIX-$n"
  UPGRADE_PASSWORD="upgrade-password-5318"
  docker network create "$UPGRADE_NET" >/dev/null
  ACTIVE_NETWORKS+=("$UPGRADE_NET")
  start_server_with_image "$UPGRADE_OLD_CONTAINER" "$UPGRADE_DATA" "$LEGACY" \
    --network "$UPGRADE_NET" --network-alias velociraptor \
    -e VELOX_DEFAULT_USER=admin \
    -e VELOX_DEFAULT_PASSWORD="$UPGRADE_PASSWORD" \
    -e VELOX_FRONTEND_HOSTNAME=velociraptor \
    -e VELOX_START_SERVER_VERBOSE=false
  assert_auth "$UPGRADE_OLD_CONTAINER" admin "$UPGRADE_PASSWORD"

  # Enroll a client against the old server and keep it running across the upgrade.
  ACTIVE_CONTAINERS+=("$UPGRADE_CLIENT")
  docker run -d --name "$UPGRADE_CLIENT" --network "$UPGRADE_NET" \
    -v "$UPGRADE_DATA/client_bundles/linux:/client:ro" "$UBUNTU_IMAGE" \
    "/client/velociraptor_client_${CLIENT_ARCH}_repacked" client >/dev/null
  old_ids=""
  for _ in $(seq 1 60); do
    old_ids="$(client_ids "$UPGRADE_OLD_CONTAINER")"
    [ -n "$old_ids" ] && break
    sleep 3
  done
  [ -n "$old_ids" ] || fail "no client enrolled with $LEGACY"
  stop_server "$UPGRADE_OLD_CONTAINER"
  upgraded_at_us="$(( $(date +%s) * 1000000 ))"

  start_server "$UPGRADE_NEW_CONTAINER" "$UPGRADE_DATA" \
    --network "$UPGRADE_NET" --network-alias velociraptor \
    -e VELOX_FRONTEND_HOSTNAME=post-upgrade-reconciled \
    -e VELOX_START_SERVER_VERBOSE=false
  assert_log_contains "$UPGRADE_NEW_CONTAINER" 'Config Mode:      reconcile'
  assert_config_value "$UPGRADE_NEW_CONTAINER" /velociraptor/server.config.yaml \
    '.Frontend.hostname' post-upgrade-reconciled
  assert_config_value "$UPGRADE_NEW_CONTAINER" /velociraptor/server.config.yaml \
    '.API.hostname' 127.0.0.1
  assert_auth "$UPGRADE_NEW_CONTAINER" admin "$UPGRADE_PASSWORD"
  assert_gui_api "$UPGRADE_NEW_CONTAINER" admin "$UPGRADE_PASSWORD"
  assert_private_config "$UPGRADE_NEW_CONTAINER"

  # The same client (same id, no re-enrollment) checks in with the new server.
  # Clients back off while the server is down; allow a few minutes.
  seen=false
  for _ in $(seq 1 100); do
    clients_json="$(docker exec "$UPGRADE_NEW_CONTAINER" curl -ksS --max-time 10 \
      -u "admin:$UPGRADE_PASSWORD" 'https://127.0.0.1:8889/api/v1/SearchClients?query=all&limit=10' || true)"
    ids="$(jq -r '[.items[]?.client_id] | sort | join(" ")' <<< "$clients_json" 2>/dev/null || true)"
    last_seen="$(jq -r '[.items[]?.last_seen_at | tonumber] | max // 0' <<< "$clients_json" 2>/dev/null || echo 0)"
    if [ "$ids" = "$(echo "$old_ids" | sort | xargs)" ] && [ "${last_seen:-0}" -gt "$upgraded_at_us" ]; then
      seen=true
      break
    fi
    sleep 3
  done
  $seen || fail "after upgrading from $LEGACY the client ($old_ids) did not check in (clients: ${ids:-none})"
  echo "  client $old_ids kept its identity across the upgrade"
  stop_server "$UPGRADE_NEW_CONTAINER"
  docker rm -f "$UPGRADE_CLIENT" >/dev/null
done

echo "--- Backward-compatible default: fresh reconcile install ---"
LEGACY_DATA="$TEST_ROOT/legacy-data"
LEGACY_CONTAINER="velo-config-legacy-$SUFFIX"
LEGACY_PASSWORD="legacy-password-8472"
start_server "$LEGACY_CONTAINER" "$LEGACY_DATA" \
  -e VELOX_DEFAULT_USER=admin \
  -e VELOX_DEFAULT_PASSWORD="$LEGACY_PASSWORD" \
  -e VELOX_FRONTEND_HOSTNAME=legacy-initial \
  -e VELOX_START_SERVER_VERBOSE=false
assert_log_contains "$LEGACY_CONTAINER" 'Config Mode:      reconcile'
assert_config_value "$LEGACY_CONTAINER" /velociraptor/server.config.yaml '.Frontend.hostname' legacy-initial
assert_auth "$LEGACY_CONTAINER" admin "$LEGACY_PASSWORD"
assert_gui_api "$LEGACY_CONTAINER" admin "$LEGACY_PASSWORD"
assert_private_config "$LEGACY_CONTAINER"
stop_server "$LEGACY_CONTAINER"

echo "--- Backward-compatible default: persisted config is still reconciled ---"
LEGACY_RESTART_CONTAINER="velo-config-restart-$SUFFIX"
start_server "$LEGACY_RESTART_CONTAINER" "$LEGACY_DATA" \
  -e VELOX_FRONTEND_HOSTNAME=legacy-reconciled \
  -e VELOX_START_SERVER_VERBOSE=false
assert_config_value "$LEGACY_RESTART_CONTAINER" /velociraptor/server.config.yaml '.Frontend.hostname' legacy-reconciled
assert_log_contains "$LEGACY_RESTART_CONTAINER" "Updating '.Frontend.hostname'"
assert_auth "$LEGACY_RESTART_CONTAINER" admin "$LEGACY_PASSWORD"
stop_server "$LEGACY_RESTART_CONTAINER"

echo "--- Generated mode: persisted config remains authoritative ---"
host_read "$LEGACY_DATA/server.config.yaml" > "$TEST_ROOT/generated-config.before"
GENERATED_CONTAINER="velo-config-generated-$SUFFIX"
start_server "$GENERATED_CONTAINER" "$LEGACY_DATA" \
  -e VELOX_CONFIG_MODE=generated \
  -e VELOX_DEFAULT_PASSWORD_FILE=/missing/bootstrap-secret \
  -e VELOX_FRONTEND_HOSTNAME=generated-must-not-apply \
  -e VELOX_START_SERVER_VERBOSE=false
assert_config_value "$GENERATED_CONTAINER" /velociraptor/server.config.yaml '.Frontend.hostname' legacy-reconciled
assert_log_contains "$GENERATED_CONTAINER" 'Generated config mode: existing configuration is authoritative'
assert_auth "$GENERATED_CONTAINER" admin "$LEGACY_PASSWORD"
stop_server "$GENERATED_CONTAINER"
host_read "$LEGACY_DATA/server.config.yaml" | cmp -s "$TEST_ROOT/generated-config.before" - || \
  fail 'generated mode unexpectedly changed the persisted server config'

echo "--- External mode: read-only config is never modified ---"
EXTERNAL_DIR="$TEST_ROOT/external"
mkdir -p "$EXTERNAL_DIR"
host_read "$LEGACY_DATA/server.config.yaml" > "$EXTERNAL_DIR/server.config.yaml"
cp "$EXTERNAL_DIR/server.config.yaml" "$TEST_ROOT/external-config.before"
# Root-only, as operators typically keep it: the server user cannot read it
# directly, so the entrypoint must hand it a private copy.
docker run --rm --entrypoint sh -v "$EXTERNAL_DIR:/e" "$IMAGE" \
  -c 'chown 0:0 /e/server.config.yaml && chmod 0400 /e/server.config.yaml'
EXTERNAL_CONTAINER="velo-config-external-$SUFFIX"
start_server "$EXTERNAL_CONTAINER" "$LEGACY_DATA" \
  -v "$EXTERNAL_DIR/server.config.yaml:/config/server.config.yaml:ro" \
  -e VELOX_CONFIG_MODE=external \
  -e VELOX_CONFIG_FILE=/config/server.config.yaml \
  -e VELOX_FRONTEND_HOSTNAME=external-must-not-apply \
  -e VELOX_START_SERVER_VERBOSE=false
assert_config_value "$EXTERNAL_CONTAINER" /config/server.config.yaml '.Frontend.hostname' legacy-reconciled
assert_log_contains "$EXTERNAL_CONTAINER" 'External config mode: configuration is read-only'
assert_log_contains "$EXTERNAL_CONTAINER" 'External config mode: skipping automatic certificate rotation'
assert_log_contains "$EXTERNAL_CONTAINER" 'Using a private copy of /config/server.config.yaml'
assert_auth "$EXTERNAL_CONTAINER" admin "$LEGACY_PASSWORD"
mount_rw="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config/server.config.yaml"}}{{.RW}}{{end}}{{end}}' "$EXTERNAL_CONTAINER")"
[ "$mount_rw" = "false" ] || fail 'external config mount was not read-only'
stop_server "$EXTERNAL_CONTAINER"
host_read "$EXTERNAL_DIR/server.config.yaml" | cmp -s "$TEST_ROOT/external-config.before" - || \
  fail 'external mode modified the read-only server config'

echo "--- Secret file: bootstrap succeeds without exposing the value ---"
SECRET_DATA="$TEST_ROOT/secret-data"
SECRET_DIR="$TEST_ROOT/secrets"
SECRET_FILE="$SECRET_DIR/admin-password"
SECRET_VALUE="file-only-password-9264"
mkdir -p "$SECRET_DIR"
printf '%s\n' "$SECRET_VALUE" > "$SECRET_FILE"
chmod 0400 "$SECRET_FILE"
SECRET_CONTAINER="velo-config-secret-$SUFFIX"
start_server "$SECRET_CONTAINER" "$SECRET_DATA" \
  -v "$SECRET_FILE:/run/secrets/velociraptor_admin_password:ro" \
  -e VELOX_CONFIG_MODE=generated \
  -e VELOX_DEFAULT_USER=admin \
  -e VELOX_DEFAULT_PASSWORD_FILE=/run/secrets/velociraptor_admin_password \
  -e VELOX_FRONTEND_HOSTNAME=secret-install \
  -e VELOX_START_SERVER_VERBOSE=false
assert_auth "$SECRET_CONTAINER" admin "$SECRET_VALUE"
inspect_output="$(docker inspect "$SECRET_CONTAINER")"
[[ "$inspect_output" != *"$SECRET_VALUE"* ]] || fail 'secret value appeared in docker inspect output'
log_output="$(docker logs "$SECRET_CONTAINER" 2>&1)"
[[ "$log_output" != *"$SECRET_VALUE"* ]] || fail 'secret value appeared in container logs'
# The server runs as uid 10001; read its environment as that user.
pid1_environment="$(docker exec -u 10001:10001 "$SECRET_CONTAINER" sh -c "tr '\000' '\n' < /proc/1/environ")"
[[ "$pid1_environment" != *"$SECRET_VALUE"* ]] || fail 'secret value remained in the server process environment'
stop_server "$SECRET_CONTAINER"

echo "--- Invalid initialization inputs fail before creating a config ---"
CONFLICT_DATA="$TEST_ROOT/conflict-data"
mkdir -p "$CONFLICT_DATA"
if docker run --rm \
  -v "$CONFLICT_DATA:/velociraptor" \
  -v "$SECRET_FILE:/run/secrets/velociraptor_admin_password:ro" \
  -e VELOX_DEFAULT_PASSWORD=conflicting-value \
  -e VELOX_DEFAULT_PASSWORD_FILE=/run/secrets/velociraptor_admin_password \
  "$IMAGE" >"$TEST_ROOT/conflict.log" 2>&1; then
  fail 'initialization accepted both password variables'
fi
grep -q 'set either VELOX_DEFAULT_PASSWORD or VELOX_DEFAULT_PASSWORD_FILE' "$TEST_ROOT/conflict.log"
[ ! -e "$CONFLICT_DATA/server.config.yaml" ] || fail 'credential conflict left a partial server config'

EMPTY_SECRET="$SECRET_DIR/empty-password"
EMPTY_SECRET_DATA="$TEST_ROOT/empty-secret-data"
: > "$EMPTY_SECRET"
mkdir -p "$EMPTY_SECRET_DATA"
if docker run --rm \
  -v "$EMPTY_SECRET_DATA:/velociraptor" \
  -v "$EMPTY_SECRET:/run/secrets/empty_password:ro" \
  -e VELOX_DEFAULT_PASSWORD_FILE=/run/secrets/empty_password \
  "$IMAGE" >"$TEST_ROOT/empty-secret.log" 2>&1; then
  fail 'initialization accepted an empty password file'
fi
grep -q 'points to an empty file' "$TEST_ROOT/empty-secret.log"
[ ! -e "$EMPTY_SECRET_DATA/server.config.yaml" ] || fail 'empty secret left a partial server config'

MISSING_SECRET_DATA="$TEST_ROOT/missing-secret-data"
mkdir -p "$MISSING_SECRET_DATA"
if docker run --rm \
  -v "$MISSING_SECRET_DATA:/velociraptor" \
  -e VELOX_DEFAULT_PASSWORD_FILE=/run/secrets/not-mounted \
  "$IMAGE" >"$TEST_ROOT/missing-secret.log" 2>&1; then
  fail 'initialization accepted a missing password file'
fi
grep -q 'does not point to a readable file' "$TEST_ROOT/missing-secret.log"
[ ! -e "$MISSING_SECRET_DATA/server.config.yaml" ] || fail 'missing secret left a partial server config'

MISSING_EXTERNAL_DATA="$TEST_ROOT/missing-external-data"
mkdir -p "$MISSING_EXTERNAL_DATA"
if docker run --rm \
  -v "$MISSING_EXTERNAL_DATA:/velociraptor" \
  -e VELOX_CONFIG_MODE=external \
  "$IMAGE" >"$TEST_ROOT/missing-external.log" 2>&1; then
  fail 'external mode accepted a missing VELOX_CONFIG_FILE'
fi
grep -q 'VELOX_CONFIG_FILE is required' "$TEST_ROOT/missing-external.log"

if docker run --rm \
  -v "$MISSING_EXTERNAL_DATA:/velociraptor" \
  -e VELOX_CONFIG_MODE=external \
  -e VELOX_CONFIG_FILE=/config/not-mounted.yaml \
  "$IMAGE" >"$TEST_ROOT/not-found-external.log" 2>&1; then
  fail 'external mode accepted a nonexistent config file'
fi
grep -q 'external Velociraptor config not found' "$TEST_ROOT/not-found-external.log"

if docker run --rm \
  -e VELOX_CONFIG_MODE=invalid \
  "$IMAGE" >"$TEST_ROOT/invalid-mode.log" 2>&1; then
  fail 'entrypoint accepted an invalid config mode'
fi
grep -q 'invalid VELOX_CONFIG_MODE' "$TEST_ROOT/invalid-mode.log"

echo "--- Special characters are stored literally (generate + reconcile) ---"
QUOTE_DATA="$TEST_ROOT/quote-data"
QUOTE_LOG_INITIAL='./logs "initial" \ dir'
QUOTE_LOG_UPDATED='./logs "updated" \ $(id) dir'
QUOTE_CONTAINER="velo-config-quote-$SUFFIX"
start_server "$QUOTE_CONTAINER" "$QUOTE_DATA" \
  -e VELOX_DEFAULT_PASSWORD=quote-password \
  -e VELOX_LOG_DIR="$QUOTE_LOG_INITIAL" \
  -e VELOX_START_SERVER_VERBOSE=false
assert_config_value "$QUOTE_CONTAINER" /velociraptor/server.config.yaml '.Logging.output_directory' "$QUOTE_LOG_INITIAL"
stop_server "$QUOTE_CONTAINER"
QUOTE_RESTART_CONTAINER="velo-config-quote-restart-$SUFFIX"
start_server "$QUOTE_RESTART_CONTAINER" "$QUOTE_DATA" \
  -e VELOX_LOG_DIR="$QUOTE_LOG_UPDATED" \
  -e VELOX_START_SERVER_VERBOSE=false
assert_config_value "$QUOTE_RESTART_CONTAINER" /velociraptor/server.config.yaml '.Logging.output_directory' "$QUOTE_LOG_UPDATED"
stop_server "$QUOTE_RESTART_CONTAINER"

echo "--- Invalid typed settings fail before creating a config ---"
BAD_PORT_DATA="$TEST_ROOT/bad-port-data"
mkdir -p "$BAD_PORT_DATA"
if docker run --rm \
  -v "$BAD_PORT_DATA:/velociraptor" \
  -e VELOX_GUI_PORT='8889, "x": 1' \
  "$IMAGE" >"$TEST_ROOT/bad-port.log" 2>&1; then
  fail 'entrypoint accepted a non-numeric port'
fi
grep -q 'VELOX_GUI_PORT must be a TCP port number' "$TEST_ROOT/bad-port.log"
[ ! -e "$BAD_PORT_DATA/server.config.yaml" ] || fail 'invalid port left a partial server config'

if docker run --rm \
  -v "$BAD_PORT_DATA:/velociraptor" \
  -e VELOX_DEBUG_DISABLED=maybe \
  "$IMAGE" >"$TEST_ROOT/bad-bool.log" 2>&1; then
  fail 'entrypoint accepted a non-boolean VELOX_DEBUG_DISABLED'
fi
grep -q "VELOX_DEBUG_DISABLED must be 'true' or 'false'" "$TEST_ROOT/bad-bool.log"

echo "--- Invalid bootstrap role fails before creating a config ---"
BAD_ROLE_DATA="$TEST_ROOT/bad-role-data"
mkdir -p "$BAD_ROLE_DATA"
if docker run --rm -v "$BAD_ROLE_DATA:/velociraptor" \
  -e VELOX_DEFAULT_USER_ROLE=admin "$IMAGE" >"$TEST_ROOT/bad-role.log" 2>&1; then
  fail 'entrypoint accepted an invalid VELOX_DEFAULT_USER_ROLE'
fi
grep -q 'VELOX_DEFAULT_USER_ROLE must be one of' "$TEST_ROOT/bad-role.log"
[ ! -e "$BAD_ROLE_DATA/server.config.yaml" ] || fail 'invalid role left a partial server config'

echo "--- Locked-out install (config without users) gets its admin on start ---"
LOCKED_DATA="$TEST_ROOT/locked-data"
LOCKED_CONTAINER="velo-config-locked-$SUFFIX"
mkdir -p "$LOCKED_DATA"
docker run --rm --entrypoint sh -v "$LOCKED_DATA:/velociraptor" "$IMAGE" \
  -c '/opt/velociraptor/linux/velociraptor config generate > /velociraptor/server.config.yaml'
# A password that looks like a flag must still be accepted literally.
start_server "$LOCKED_CONTAINER" "$LOCKED_DATA" \
  -e VELOX_DEFAULT_PASSWORD='-n' \
  -e VELOX_START_SERVER_VERBOSE=false
assert_log_contains "$LOCKED_CONTAINER" "Creating default user 'admin'"
assert_auth "$LOCKED_CONTAINER" admin '-n'
stop_server "$LOCKED_CONTAINER"

echo "--- A public URL behind a proxy does not move the listening ports ---"
PROXY_DATA="$TEST_ROOT/proxy-data"
PROXY_CONTAINER="velo-config-proxy-$SUFFIX"
start_server "$PROXY_CONTAINER" "$PROXY_DATA" \
  -e VELOX_DEFAULT_PASSWORD=proxy-password \
  -e VELOX_FRONTEND_SERVER_URL=https://ingest.example.com \
  -e VELOX_GUI_URL=https://admin.example.com/ \
  -e VELOX_START_SERVER_VERBOSE=false
assert_config_value "$PROXY_CONTAINER" /velociraptor/server.config.yaml '.Frontend.bind_port' 8000
assert_config_value "$PROXY_CONTAINER" /velociraptor/server.config.yaml '.GUI.bind_port' 8889
assert_config_value "$PROXY_CONTAINER" /velociraptor/server.config.yaml '.Client.server_urls[0]' https://ingest.example.com/
assert_config_value "$PROXY_CONTAINER" /velociraptor/server.config.yaml '.GUI.public_url' https://admin.example.com/app/index.html
assert_gui_api "$PROXY_CONTAINER" admin proxy-password
stop_server "$PROXY_CONTAINER"

echo "--- Declarative artifacts: manifest installs, disables, overrides and removes ---"
MF_NET="velo-mf-$SUFFIX"
MF_WEB="velo-mf-web-$SUFFIX"
MF_DATA="$TEST_ROOT/manifest-data"
MF_WWW="$TEST_ROOT/manifest-www"
MF_CONTAINER="velo-config-manifest-$SUFFIX"
MF_PASSWORD="manifest-password"
mkdir -p "$MF_WWW/pack" "$MF_DATA/artifacts"
chmod 0755 "$MF_WWW" "$MF_WWW/pack" "$MF_DATA" "$MF_DATA/artifacts"
printf 'name: Custom.Url.Single\nsources:\n  - query: SELECT 1 AS One FROM scope()\n' > "$MF_WWW/single.yaml"
printf 'name: Custom.Zip.Keep\nsources:\n  - query: SELECT 2 AS Two FROM scope()\n' > "$MF_WWW/pack/keep.yaml"
printf 'name: Custom.Zip.Skip\nsources:\n  - query: SELECT 3 AS Three FROM scope()\n' > "$MF_WWW/pack/skip.yaml"
printf 'title: a detection rule, not an artifact\n' > "$MF_WWW/pack/rule.yml"
chmod 0644 "$MF_WWW"/*.yaml "$MF_WWW"/pack/*
docker run --rm --entrypoint python3 -v "$MF_WWW:/www" -w /www "$IMAGE" -c '
import zipfile
with zipfile.ZipFile("pack.zip", "w") as z:
    for f in ("keep.yaml", "skip.yaml", "rule.yml"):
        z.write("pack/" + f, f)'
single_sha="$(sha256sum "$MF_WWW/single.yaml" | awk '{print $1}')"
pack_sha="$(host_read "$MF_WWW/pack.zip" | sha256sum | awk '{print $1}')"
printf 'name: Windows.Sigma.Triage\ndescription: operator override\nsources:\n  - query: SELECT 9 AS Nine FROM scope()\n' > "$MF_DATA/artifacts/override.yaml"
{
  echo "artifacts:"
  echo "  - url: http://web:8080/single.yaml"
  echo "    sha256: ${single_sha}"
  echo "  - url: http://web:8080/pack.zip"
  echo "    sha256: ${pack_sha}"
  echo "    include: [Custom.Zip.Keep]"
  echo "disable:"
  echo "  - Windows.Hayabusa.Monitoring"
} > "$MF_DATA/artifacts.yaml"
chmod 0644 "$MF_DATA/artifacts.yaml" "$MF_DATA/artifacts/override.yaml"
docker network create "$MF_NET" >/dev/null
ACTIVE_NETWORKS+=("$MF_NET")
ACTIVE_CONTAINERS+=("$MF_WEB")
docker run -d --name "$MF_WEB" --network "$MF_NET" --network-alias web \
  -v "$MF_WWW:/www:ro" -w /www --entrypoint python3 "$IMAGE" -m http.server 8080 >/dev/null

# artifact_state CONTAINER NAME -> loaded | absent (as the running server sees it)
artifact_state() {
  local body
  body="$(docker exec "$1" curl -ksS --max-time 10 -u "admin:$MF_PASSWORD" \
    "https://127.0.0.1:8889/api/v1/GetArtifactFile?name=$2" | jq -r '.artifact // empty' | head -n1)"
  case "$body" in
    "name: Custom.$2"|"name: $2") echo loaded ;;
    *) echo absent ;;
  esac
}
expect_artifact() {
  local state
  state="$(artifact_state "$1" "$2")"
  [ "$state" = "$3" ] || fail "$1: expected $2 to be $3, got $state"
}

start_server "$MF_CONTAINER" "$MF_DATA" --network "$MF_NET" \
  -e VELOX_DEFAULT_PASSWORD="$MF_PASSWORD" -e VELOX_START_SERVER_VERBOSE=false
expect_artifact "$MF_CONTAINER" Custom.Url.Single loaded
expect_artifact "$MF_CONTAINER" Custom.Zip.Keep loaded
expect_artifact "$MF_CONTAINER" Custom.Zip.Skip absent
expect_artifact "$MF_CONTAINER" Windows.Hayabusa.Monitoring absent
expect_artifact "$MF_CONTAINER" Windows.Hayabusa.Rules loaded
override="$(docker exec "$MF_CONTAINER" curl -ksS -u "admin:$MF_PASSWORD" \
  'https://127.0.0.1:8889/api/v1/GetArtifactFile?name=Windows.Sigma.Triage' | jq -r .artifact)"
[[ "$override" == *"operator override"* ]] || fail 'extra-directory artifact did not replace the bundled one'
assert_log_contains "$MF_CONTAINER" '[artifacts] loaded: 10 bundled, 1 extra, 2 manifest'
stop_server "$MF_CONTAINER"

# Remove one entry and take the web server away: the other comes from cache.
docker rm -f "$MF_WEB" >/dev/null
docker run --rm --entrypoint sh -v "$MF_DATA:/velociraptor" "$IMAGE" \
  -c "sed -i '/single.yaml/,+1d' /velociraptor/artifacts.yaml"
MF_RESTART="velo-config-manifest-restart-$SUFFIX"
start_server "$MF_RESTART" "$MF_DATA" --network "$MF_NET" \
  -e VELOX_START_SERVER_VERBOSE=false -e VELOX_DISABLE_ARTIFACTS=Windows.Hayabusa.Rules
expect_artifact "$MF_RESTART" Custom.Url.Single absent
expect_artifact "$MF_RESTART" Custom.Zip.Keep loaded
expect_artifact "$MF_RESTART" Windows.Hayabusa.Rules absent
assert_log_contains "$MF_RESTART" '[artifacts] cached http://web:8080/pack.zip'
stop_server "$MF_RESTART"

# A wrong checksum stops the start (strict default) and is skipped when not strict.
docker rm -f "$MF_WEB" >/dev/null 2>&1 || true
docker run -d --name "$MF_WEB" --network "$MF_NET" --network-alias web \
  -v "$MF_WWW:/www:ro" -w /www --entrypoint python3 "$IMAGE" -m http.server 8080 >/dev/null
# All-"f" rather than all-zero: YAML would read 000... as the number 0.
wrong_sha="$(printf 'f%.0s' $(seq 1 64))"
docker run --rm --entrypoint sh -v "$MF_DATA:/velociraptor" "$IMAGE" \
  -c "sed -i 's/${pack_sha}/${wrong_sha}/' /velociraptor/artifacts.yaml"
if docker run --rm --network "$MF_NET" -v "$MF_DATA:/velociraptor" "$IMAGE" \
    >"$TEST_ROOT/manifest-strict.log" 2>&1; then
  fail 'a manifest entry with a wrong checksum did not stop the start'
fi
grep -q 'FATAL: manifest.*sha256 mismatch' "$TEST_ROOT/manifest-strict.log" || fail 'strict manifest checksum failure was not reported'
MF_LENIENT="velo-config-manifest-lenient-$SUFFIX"
start_server "$MF_LENIENT" "$MF_DATA" --network "$MF_NET" \
  -e VELOX_ARTIFACTS_STRICT=false -e VELOX_START_SERVER_VERBOSE=false
# Only the failing entry is skipped; the manifest's disable list still applies.
expect_artifact "$MF_LENIENT" Custom.Zip.Keep absent
expect_artifact "$MF_LENIENT" Windows.Hayabusa.Monitoring absent
assert_log_contains "$MF_LENIENT" 'WARNING: skipping manifest entry'
stop_server "$MF_LENIENT"

echo "Config mode and secret-file validation: PASS"
