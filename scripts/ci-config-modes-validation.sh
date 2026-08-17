#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-velociraptor:smoke}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-300}"
TEST_ROOT="$(mktemp -d)"
SUFFIX="$$-${RANDOM}"
ACTIVE_CONTAINERS=()

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

if [ -n "${LEGACY_IMAGE:-}" ]; then
  echo "--- Real upgrade: pre-feature image to backward-compatible default ---"
  UPGRADE_DATA="$TEST_ROOT/upgrade-data"
  UPGRADE_OLD_CONTAINER="velo-config-upgrade-old-$SUFFIX"
  UPGRADE_NEW_CONTAINER="velo-config-upgrade-new-$SUFFIX"
  UPGRADE_PASSWORD="upgrade-password-5318"
  start_server_with_image "$UPGRADE_OLD_CONTAINER" "$UPGRADE_DATA" "$LEGACY_IMAGE" \
    -e VELOX_DEFAULT_USER=admin \
    -e VELOX_DEFAULT_PASSWORD="$UPGRADE_PASSWORD" \
    -e VELOX_FRONTEND_HOSTNAME=pre-feature-install \
    -e VELOX_START_SERVER_VERBOSE=false
  assert_auth "$UPGRADE_OLD_CONTAINER" admin "$UPGRADE_PASSWORD"
  stop_server "$UPGRADE_OLD_CONTAINER"

  start_server "$UPGRADE_NEW_CONTAINER" "$UPGRADE_DATA" \
    -e VELOX_FRONTEND_HOSTNAME=post-upgrade-reconciled \
    -e VELOX_START_SERVER_VERBOSE=false
  assert_log_contains "$UPGRADE_NEW_CONTAINER" 'Config Mode:      reconcile'
  assert_config_value "$UPGRADE_NEW_CONTAINER" /velociraptor/server.config.yaml \
    '.Frontend.hostname' post-upgrade-reconciled
  assert_auth "$UPGRADE_NEW_CONTAINER" admin "$UPGRADE_PASSWORD"
  stop_server "$UPGRADE_NEW_CONTAINER"
fi

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
cp "$LEGACY_DATA/server.config.yaml" "$TEST_ROOT/generated-config.before"
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
cmp -s "$TEST_ROOT/generated-config.before" "$LEGACY_DATA/server.config.yaml" || \
  fail 'generated mode unexpectedly changed the persisted server config'

echo "--- External mode: read-only config is never modified ---"
EXTERNAL_DIR="$TEST_ROOT/external"
mkdir -p "$EXTERNAL_DIR"
cp "$LEGACY_DATA/server.config.yaml" "$EXTERNAL_DIR/server.config.yaml"
cp "$EXTERNAL_DIR/server.config.yaml" "$TEST_ROOT/external-config.before"
chmod 0444 "$EXTERNAL_DIR/server.config.yaml"
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
assert_auth "$EXTERNAL_CONTAINER" admin "$LEGACY_PASSWORD"
mount_rw="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config/server.config.yaml"}}{{.RW}}{{end}}{{end}}' "$EXTERNAL_CONTAINER")"
[ "$mount_rw" = "false" ] || fail 'external config mount was not read-only'
stop_server "$EXTERNAL_CONTAINER"
cmp -s "$TEST_ROOT/external-config.before" "$EXTERNAL_DIR/server.config.yaml" || \
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
pid1_environment="$(docker exec "$SECRET_CONTAINER" sh -c "tr '\000' '\n' < /proc/1/environ")"
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

echo "Config mode and secret-file validation: PASS"
