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

# Optional expected sha256 per asset. Empty = skip verification.
ARG VELOX_SHA256_LINUX_AMD64=
ARG VELOX_SHA256_LINUX_ARM64=
ARG VELOX_SHA256_DARWIN_AMD64=
ARG VELOX_SHA256_DARWIN_ARM64=
ARG VELOX_SHA256_WINDOWS_EXE=
ARG VELOX_SHA256_WINDOWS_MSI=

ENV DEBIAN_FRONTEND=noninteractive \
    VELOX_VERSION=${VELOX_VERSION} \
    TARGETARCH=${TARGETARCH} \
    GIT_COMMIT=${GIT_COMMIT:-unknown} \
    BUILD_DATE=${BUILD_DATE:-unknown} \
    BASE_IMAGE=${BASE_IMAGE}

COPY ./entrypoint /entrypoint
RUN chmod +x /entrypoint && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl jq yq dpkg-dev rpm openssl && \
    mkdir -p /opt/velociraptor/linux /opt/velociraptor/mac /opt/velociraptor/windows && \
    rm -rf /var/lib/apt/lists/*

# Velocidex release model:
#   * Git tag is the MINOR version: v0.76
#   * Each patch (v0.76.5, v0.76.6, ...) is published as a new asset
#     attached to that same minor release.
#   * Asset filename: velociraptor-vX.Y.Z-<platform>  (the "v" stays).
# So:
#   * URL path uses the minor tag: ${VERSION%.*}  (v0.76.5 -> v0.76)
#   * Filename uses the full version including "v": v0.76.5
# Server binary: must match the image's TARGETARCH and must succeed.
# Client binaries (cross-arch + mac + windows): tolerant; missing assets
# are skipped here and handled by the entrypoint repack logic.
RUN set -eux; \
    fetch() { \
      local url="$1" out="$2" required="$3" expect_sha="$4"; \
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
      if [ "$required" = "true" ]; then \
        echo "FATAL: required asset missing: $url" >&2; \
        return 1; \
      fi; \
      echo "  (optional asset not available; skipping)"; \
      rm -f "$out"; \
      return 0; \
    }; \
    minor_tag() { echo "${1%.*}"; }; \
    BASE="https://github.com/Velocidex/velociraptor/releases/download"; \
    \
    LINUX_AMD64_V="${VELOX_VERSION_LINUX_AMD64}";   LINUX_AMD64_T="$(minor_tag "$LINUX_AMD64_V")"; \
    LINUX_ARM64_V="${VELOX_VERSION_LINUX_ARM64}";   LINUX_ARM64_T="$(minor_tag "$LINUX_ARM64_V")"; \
    DARWIN_AMD64_V="${VELOX_VERSION_DARWIN_AMD64}"; DARWIN_AMD64_T="$(minor_tag "$DARWIN_AMD64_V")"; \
    DARWIN_ARM64_V="${VELOX_VERSION_DARWIN_ARM64}"; DARWIN_ARM64_T="$(minor_tag "$DARWIN_ARM64_V")"; \
    WINDOWS_EXE_V="${VELOX_VERSION_WINDOWS_EXE}";   WINDOWS_EXE_T="$(minor_tag "$WINDOWS_EXE_V")"; \
    WINDOWS_MSI_V="${VELOX_VERSION_WINDOWS_MSI}";   WINDOWS_MSI_T="$(minor_tag "$WINDOWS_MSI_V")"; \
    \
    case "${TARGETARCH}" in \
      amd64) SERVER_V="$LINUX_AMD64_V"; SERVER_T="$LINUX_AMD64_T"; SERVER_SHA="${VELOX_SHA256_LINUX_AMD64}" ;; \
      arm64) SERVER_V="$LINUX_ARM64_V"; SERVER_T="$LINUX_ARM64_T"; SERVER_SHA="${VELOX_SHA256_LINUX_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    echo "Downloading server binary (${TARGETARCH}, ${SERVER_V}):"; \
    fetch "${BASE}/${SERVER_T}/velociraptor-${SERVER_V}-linux-${TARGETARCH}" \
          /opt/velociraptor/linux/velociraptor true "$SERVER_SHA"; \
    chmod +x /opt/velociraptor/linux/velociraptor; \
    \
    echo "Downloading client binaries (tolerant):"; \
    fetch "${BASE}/${LINUX_AMD64_T}/velociraptor-${LINUX_AMD64_V}-linux-amd64" \
          /opt/velociraptor/linux/velociraptor_client_amd64 false "${VELOX_SHA256_LINUX_AMD64}"; \
    fetch "${BASE}/${LINUX_ARM64_T}/velociraptor-${LINUX_ARM64_V}-linux-arm64" \
          /opt/velociraptor/linux/velociraptor_client_arm64 false "${VELOX_SHA256_LINUX_ARM64}"; \
    fetch "${BASE}/${DARWIN_AMD64_T}/velociraptor-${DARWIN_AMD64_V}-darwin-amd64" \
          /opt/velociraptor/mac/velociraptor_client_amd64 false "${VELOX_SHA256_DARWIN_AMD64}"; \
    fetch "${BASE}/${DARWIN_ARM64_T}/velociraptor-${DARWIN_ARM64_V}-darwin-arm64" \
          /opt/velociraptor/mac/velociraptor_client_arm64 false "${VELOX_SHA256_DARWIN_ARM64}"; \
    fetch "${BASE}/${WINDOWS_EXE_T}/velociraptor-${WINDOWS_EXE_V}-windows-amd64.exe" \
          /opt/velociraptor/windows/velociraptor_client.exe false "${VELOX_SHA256_WINDOWS_EXE}"; \
    fetch "${BASE}/${WINDOWS_MSI_T}/velociraptor-${WINDOWS_MSI_V}-windows-amd64.msi" \
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

WORKDIR /velociraptor

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -fkso /dev/null "https://127.0.0.1:${VELOX_GUI_PORT:-8889}/" || exit 1

ENTRYPOINT ["/entrypoint"]
