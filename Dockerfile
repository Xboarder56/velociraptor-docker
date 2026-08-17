ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE}

ARG VELOX_VERSION
ARG TARGETARCH
ARG GIT_COMMIT
ARG BUILD_DATE
ARG BASE_IMAGE

# Per-asset version overrides (default to VELOX_VERSION).
# Set by the build workflow from binaries.lock when upstream has not
# published an asset for the main VELOX_VERSION yet.
ARG VELOX_VERSION_LINUX_AMD64=${VELOX_VERSION}
ARG VELOX_VERSION_LINUX_ARM64=${VELOX_VERSION}
ARG VELOX_VERSION_DARWIN_AMD64=${VELOX_VERSION}
ARG VELOX_VERSION_DARWIN_ARM64=${VELOX_VERSION}
ARG VELOX_VERSION_WINDOWS_EXE=${VELOX_VERSION}
ARG VELOX_VERSION_WINDOWS_MSI=${VELOX_VERSION}

# Exact per-asset release URLs. CI sets these from binaries.lock because
# Velocidex uses both full patch tags and legacy minor tags for releases.
# Empty values retain convenient version-only local builds.
ARG VELOX_URL_LINUX_AMD64=
ARG VELOX_URL_LINUX_ARM64=
ARG VELOX_URL_DARWIN_AMD64=
ARG VELOX_URL_DARWIN_ARM64=
ARG VELOX_URL_WINDOWS_EXE=
ARG VELOX_URL_WINDOWS_MSI=

# Optional expected sha256 per asset. Empty = skip verification.
ARG VELOX_SHA256_LINUX_AMD64=
ARG VELOX_SHA256_LINUX_ARM64=
ARG VELOX_SHA256_DARWIN_AMD64=
ARG VELOX_SHA256_DARWIN_ARM64=
ARG VELOX_SHA256_WINDOWS_EXE=
ARG VELOX_SHA256_WINDOWS_MSI=

# Official Velocidex Triage definitions, pinned by artifacts.lock.
ARG TRIAGE_SOURCE_COMMIT=unknown
ARG TRIAGE_LINUX_UAC_URL=
ARG TRIAGE_LINUX_UAC_SHA256=
ARG TRIAGE_WINDOWS_TARGETS_URL=
ARG TRIAGE_WINDOWS_TARGETS_SHA256=

ENV DEBIAN_FRONTEND=noninteractive \
    VELOX_VERSION=${VELOX_VERSION} \
    TARGETARCH=${TARGETARCH} \
    GIT_COMMIT=${GIT_COMMIT:-unknown} \
    BUILD_DATE=${BUILD_DATE:-unknown} \
    BASE_IMAGE=${BASE_IMAGE} \
    VELOX_TRIAGE_SOURCE_COMMIT=${TRIAGE_SOURCE_COMMIT}

COPY ./entrypoint /entrypoint
RUN chmod +x /entrypoint && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl jq yq dpkg-dev rpm openssl && \
    mkdir -p /opt/velociraptor/linux /opt/velociraptor/mac /opt/velociraptor/windows && \
    rm -rf /var/lib/apt/lists/*

# Velocidex has used two release layouts:
#   * Current: full patch tag (v0.77.2) and full patch asset filename.
#   * Legacy: minor tag (v0.76) with patch assets attached to it.
# CI supplies the exact URL recorded by upstream-check. For version-only local
# builds, fetch_asset tries the current layout and then the legacy layout.
# Server binary: must match the image's TARGETARCH and must succeed.
# Client binaries (cross-arch + mac + windows): tolerant; missing assets
# are skipped here and handled by the entrypoint repack logic.
RUN set -eux; \
    fetch_asset() { \
      local pinned_url="$1" version="$2" suffix="$3" out="$4" required="$5" expect_sha="$6"; \
      local asset="velociraptor-${version}-${suffix}"; \
      local primary_url legacy_url url actual_sha; \
      if [ -n "$pinned_url" ]; then \
        primary_url="$pinned_url"; \
        legacy_url=""; \
      else \
        primary_url="${BASE}/${version}/${asset}"; \
        legacy_url="${BASE}/${version%.*}/${asset}"; \
        if [ "$legacy_url" = "$primary_url" ]; then legacy_url=""; fi; \
      fi; \
      for url in "$primary_url" "$legacy_url"; do \
        if [ -z "$url" ]; then continue; fi; \
        echo "  $url"; \
        if curl -fL --retry 3 --retry-delay 2 "$url" -o "$out"; then \
          if [ -n "$expect_sha" ]; then \
            actual_sha="$(sha256sum "$out" | awk '{print $1}')"; \
            if [ "$actual_sha" != "$expect_sha" ]; then \
              echo "FATAL: sha256 mismatch for $out" >&2; \
              echo "  expected: $expect_sha" >&2; \
              echo "  actual:   $actual_sha" >&2; \
              return 1; \
            fi; \
          fi; \
          return 0; \
        fi; \
        rm -f "$out"; \
      done; \
      if [ "$required" = "true" ]; then \
        echo "FATAL: required asset missing: $asset" >&2; \
        return 1; \
      fi; \
      echo "  (optional asset not available; skipping)"; \
      return 0; \
    }; \
    BASE="https://github.com/Velocidex/velociraptor/releases/download"; \
    \
    LINUX_AMD64_V="${VELOX_VERSION_LINUX_AMD64}"; \
    LINUX_ARM64_V="${VELOX_VERSION_LINUX_ARM64}"; \
    DARWIN_AMD64_V="${VELOX_VERSION_DARWIN_AMD64}"; \
    DARWIN_ARM64_V="${VELOX_VERSION_DARWIN_ARM64}"; \
    WINDOWS_EXE_V="${VELOX_VERSION_WINDOWS_EXE}"; \
    WINDOWS_MSI_V="${VELOX_VERSION_WINDOWS_MSI}"; \
    \
    case "${TARGETARCH}" in \
      amd64) SERVER_V="$LINUX_AMD64_V"; SERVER_URL="${VELOX_URL_LINUX_AMD64}"; SERVER_SHA="${VELOX_SHA256_LINUX_AMD64}" ;; \
      arm64) SERVER_V="$LINUX_ARM64_V"; SERVER_URL="${VELOX_URL_LINUX_ARM64}"; SERVER_SHA="${VELOX_SHA256_LINUX_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    echo "Downloading server binary (${TARGETARCH}, ${SERVER_V}):"; \
    fetch_asset "$SERVER_URL" "$SERVER_V" "linux-${TARGETARCH}" \
                /opt/velociraptor/linux/velociraptor true "$SERVER_SHA"; \
    chmod +x /opt/velociraptor/linux/velociraptor; \
    \
    echo "Downloading client binaries (tolerant):"; \
    fetch_asset "${VELOX_URL_LINUX_AMD64}" "$LINUX_AMD64_V" linux-amd64 \
                /opt/velociraptor/linux/velociraptor_client_amd64 false "${VELOX_SHA256_LINUX_AMD64}"; \
    fetch_asset "${VELOX_URL_LINUX_ARM64}" "$LINUX_ARM64_V" linux-arm64 \
                /opt/velociraptor/linux/velociraptor_client_arm64 false "${VELOX_SHA256_LINUX_ARM64}"; \
    fetch_asset "${VELOX_URL_DARWIN_AMD64}" "$DARWIN_AMD64_V" darwin-amd64 \
                /opt/velociraptor/mac/velociraptor_client_amd64 false "${VELOX_SHA256_DARWIN_AMD64}"; \
    fetch_asset "${VELOX_URL_DARWIN_ARM64}" "$DARWIN_ARM64_V" darwin-arm64 \
                /opt/velociraptor/mac/velociraptor_client_arm64 false "${VELOX_SHA256_DARWIN_ARM64}"; \
    fetch_asset "${VELOX_URL_WINDOWS_EXE}" "$WINDOWS_EXE_V" windows-amd64.exe \
                /opt/velociraptor/windows/velociraptor_client.exe false "${VELOX_SHA256_WINDOWS_EXE}"; \
    fetch_asset "${VELOX_URL_WINDOWS_MSI}" "$WINDOWS_MSI_V" windows-amd64.msi \
                /opt/velociraptor/windows/velociraptor_client.msi false "${VELOX_SHA256_WINDOWS_MSI}"; \
    echo "Downloads done."

# Bake checksums next to each present binary so the entrypoint can
# detect upstream binary changes across rebuilds.
RUN set -eux; \
  for f in \
    /opt/velociraptor/linux/velociraptor \
    /opt/velociraptor/linux/velociraptor_client_amd64 \
    /opt/velociraptor/linux/velociraptor_client_arm64 \
    /opt/velociraptor/mac/velociraptor_client_amd64 \
    /opt/velociraptor/mac/velociraptor_client_arm64 \
    /opt/velociraptor/windows/velociraptor_client.exe \
    /opt/velociraptor/windows/velociraptor_client.msi \
  ; do \
    if [ -s "$f" ]; then \
      sha256sum "$f" | awk '{print $1}' > "${f}.sha256"; \
    fi; \
  done

# Bundle official custom definitions as immutable, verified build inputs.
# The frontend loads this directory on every start via --definitions.
RUN set -eux; \
  fetch_definition() { \
    local url="$1" out="$2" expect_sha="$3" actual_sha; \
    if [ -z "$url" ] || [ -z "$expect_sha" ]; then \
      echo "FATAL: bundled artifact URL and sha256 are required" >&2; \
      return 1; \
    fi; \
    echo "  $url"; \
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$out"; \
    actual_sha="$(sha256sum "$out" | awk '{print $1}')"; \
    if [ "$actual_sha" != "$expect_sha" ]; then \
      echo "FATAL: sha256 mismatch for $out" >&2; \
      echo "  expected: $expect_sha" >&2; \
      echo "  actual:   $actual_sha" >&2; \
      return 1; \
    fi; \
  }; \
  mkdir -p /opt/velociraptor/artifacts; \
  fetch_definition "$TRIAGE_LINUX_UAC_URL" \
    /opt/velociraptor/artifacts/Linux.Triage.UAC.yaml \
    "$TRIAGE_LINUX_UAC_SHA256"; \
  fetch_definition "$TRIAGE_WINDOWS_TARGETS_URL" \
    /opt/velociraptor/artifacts/Windows.Triage.Targets.yaml \
    "$TRIAGE_WINDOWS_TARGETS_SHA256"; \
  /opt/velociraptor/linux/velociraptor artifacts verify --builtin \
    /opt/velociraptor/artifacts/Linux.Triage.UAC.yaml \
    /opt/velociraptor/artifacts/Windows.Triage.Targets.yaml

WORKDIR /velociraptor

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -fkso /dev/null "https://127.0.0.1:${VELOX_GUI_PORT:-8889}/" || exit 1

ENTRYPOINT ["/entrypoint"]
