# Base image pinned by digest (Dependabot keeps it current). CI reads the
# first FROM line to record the base image name and digest in the labels.
FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS sigma

# Velocidex Sigma / Hayabusa pack, pinned by artifacts.lock. Extracted in this
# throwaway stage so the runtime image needs no unzip. SIGMA_ARTIFACTS lists
# "<file in the pack>:<artifact name>"; each output is named after its artifact.
ARG SIGMA_ARTIFACTS_URL=
ARG SIGMA_ARTIFACTS_SHA256=
ARG SIGMA_ARTIFACTS=
RUN set -eux; \
    if [ -z "$SIGMA_ARTIFACTS_URL" ] || [ -z "$SIGMA_ARTIFACTS_SHA256" ] || [ -z "$SIGMA_ARTIFACTS" ]; then \
      echo "FATAL: SIGMA_ARTIFACTS_URL, SIGMA_ARTIFACTS_SHA256 and SIGMA_ARTIFACTS are required (see scripts/build.sh)" >&2; \
      exit 1; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    curl -fL --retry 3 --retry-delay 2 "$SIGMA_ARTIFACTS_URL" -o /tmp/sigma.zip; \
    echo "$SIGMA_ARTIFACTS_SHA256  /tmp/sigma.zip" | sha256sum -c -; \
    mkdir -p /out; \
    for pair in $SIGMA_ARTIFACTS; do \
      src="${pair%%:*}" name="${pair#*:}"; \
      unzip -p /tmp/sigma.zip "output/${src}.yaml" > "/out/${name}.yaml"; \
      grep -qx "name: ${name}" "/out/${name}.yaml"; \
    done; \
    ls -l /out

FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

ARG VELOX_VERSION
ARG TARGETARCH

# Per-asset version overrides (default to VELOX_VERSION).
# Set by the build workflow from binaries.lock when upstream has not
# published an asset for the main VELOX_VERSION yet.
ARG VELOX_VERSION_LINUX_AMD64=${VELOX_VERSION}
ARG VELOX_VERSION_LINUX_ARM64=${VELOX_VERSION}
ARG VELOX_VERSION_LINUX_AMD64_MUSL=${VELOX_VERSION}
ARG VELOX_VERSION_DARWIN_AMD64=${VELOX_VERSION}
ARG VELOX_VERSION_DARWIN_ARM64=${VELOX_VERSION}
ARG VELOX_VERSION_WINDOWS_EXE=${VELOX_VERSION}
ARG VELOX_VERSION_WINDOWS_MSI=${VELOX_VERSION}

# Exact per-asset release URLs. CI sets these from binaries.lock because
# Velocidex uses both full patch tags and legacy minor tags for releases.
# Empty values retain convenient version-only local builds.
ARG VELOX_URL_LINUX_AMD64=
ARG VELOX_URL_LINUX_ARM64=
ARG VELOX_URL_LINUX_AMD64_MUSL=
ARG VELOX_URL_DARWIN_AMD64=
ARG VELOX_URL_DARWIN_ARM64=
ARG VELOX_URL_WINDOWS_EXE=
ARG VELOX_URL_WINDOWS_MSI=

# Optional expected sha256 per asset (of the downloaded file). CI always sets
# these from binaries.lock. Independently of them, every binary must carry a
# valid Velocidex release signature (see VELOX_VERIFY_SIGNATURES).
ARG VELOX_SHA256_LINUX_AMD64=
ARG VELOX_SHA256_LINUX_ARM64=
ARG VELOX_SHA256_LINUX_AMD64_MUSL=
ARG VELOX_SHA256_DARWIN_AMD64=
ARG VELOX_SHA256_DARWIN_ARM64=
ARG VELOX_SHA256_WINDOWS_EXE=
ARG VELOX_SHA256_WINDOWS_MSI=

# Verify each downloaded binary against its upstream .sig with the pinned
# Velocidex release key (keys/velocidex-release.gpg). Only disable this for
# local experiments with unsigned builds.
ARG VELOX_VERIFY_SIGNATURES=true

# Official Velocidex Triage definitions, pinned by artifacts.lock.
ARG TRIAGE_SOURCE_COMMIT=unknown
ARG SIGMA_SOURCE_COMMIT=unknown
ARG TRIAGE_LINUX_UAC_URL=
ARG TRIAGE_LINUX_UAC_SHA256=
ARG TRIAGE_WINDOWS_TARGETS_URL=
ARG TRIAGE_WINDOWS_TARGETS_SHA256=

ENV DEBIAN_FRONTEND=noninteractive

# The server drops to this unprivileged account after the entrypoint has
# prepared the data volume (override with VELOX_UID/VELOX_GID at runtime).
# Package tooling is not needed: Velociraptor builds .deb/.rpm itself.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gzip jq yq openssl; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --system --gid 10001 velociraptor; \
    useradd --system --uid 10001 --gid 10001 --home-dir /velociraptor \
      --no-create-home --shell /usr/sbin/nologin velociraptor; \
    mkdir -p /opt/velociraptor/linux /opt/velociraptor/mac /opt/velociraptor/windows

COPY keys/velocidex-release.gpg /opt/velociraptor/keys/velocidex-release.gpg

# Velocidex has used several release layouts:
#   * v0.77.3+: full patch tag, binaries published gzipped (*.gz); MSI raw.
#   * v0.77.0-v0.77.2: full patch tag, raw binaries.
#   * Legacy: minor tag (v0.76) with patch assets attached to it.
# CI supplies the exact URL recorded by upstream-check. For version-only local
# builds, fetch_asset tries the current layouts and then the legacy layout.
# The sha256 (when given) is of the downloaded file, i.e. the .gz for gzipped
# assets, which matches the digest GitHub publishes for the release asset.
# The upstream signature (<asset without .gz>.sig) covers the uncompressed
# binary and is checked after decompression.
# Server binary: must match the image's TARGETARCH and must succeed.
# Client binaries (cross-arch + mac + windows): tolerant; missing assets
# are skipped here and handled by the entrypoint repack logic.
RUN set -eux; \
    fetch_asset() { \
      local pinned_url="$1" version="$2" suffix="$3" out="$4" required="$5" expect_sha="$6"; \
      local asset="velociraptor-${version}-${suffix}"; \
      local urls url actual_sha dl; \
      if [ -n "$pinned_url" ]; then \
        urls="$pinned_url"; \
      else \
        urls="${BASE}/${version}/${asset} ${BASE}/${version}/${asset}.gz"; \
        if [ "${version%.*}" != "$version" ]; then \
          urls="$urls ${BASE}/${version%.*}/${asset}"; \
        fi; \
      fi; \
      for url in $urls; do \
        echo "  $url"; \
        dl="${out}.download"; \
        if curl -fL --retry 3 --retry-delay 2 "$url" -o "$dl"; then \
          if [ -n "$expect_sha" ]; then \
            actual_sha="$(sha256sum "$dl" | awk '{print $1}')"; \
            if [ "$actual_sha" != "$expect_sha" ]; then \
              echo "FATAL: sha256 mismatch for $url" >&2; \
              echo "  expected: $expect_sha" >&2; \
              echo "  actual:   $actual_sha" >&2; \
              rm -f "$dl"; \
              return 1; \
            fi; \
          fi; \
          case "$url" in \
            *.gz) gzip -dc "$dl" > "$out"; rm -f "$dl" ;; \
            *)    mv -f "$dl" "$out" ;; \
          esac; \
          if [ "$VELOX_VERIFY_SIGNATURES" = "true" ]; then \
            curl -fsSL --retry 3 --retry-delay 2 "${url%.gz}.sig" -o "${out}.sig"; \
            if ! gpgv --keyring /opt/velociraptor/keys/velocidex-release.gpg \
                "${out}.sig" "$out"; then \
              echo "FATAL: bad Velocidex signature for $url" >&2; \
              rm -f "$out" "${out}.sig"; \
              return 1; \
            fi; \
            rm -f "${out}.sig"; \
          fi; \
          return 0; \
        fi; \
        rm -f "$dl"; \
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
    LINUX_AMD64_MUSL_V="${VELOX_VERSION_LINUX_AMD64_MUSL}"; \
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
    for arch in amd64 arm64; do \
      if [ "$arch" = "$TARGETARCH" ]; then \
        # The native Linux client is the server binary: hard link, no second copy.
        ln /opt/velociraptor/linux/velociraptor /opt/velociraptor/linux/velociraptor_client_${arch}; \
      elif [ "$arch" = amd64 ]; then \
        fetch_asset "${VELOX_URL_LINUX_AMD64}" "$LINUX_AMD64_V" linux-amd64 \
                    /opt/velociraptor/linux/velociraptor_client_amd64 false "${VELOX_SHA256_LINUX_AMD64}"; \
      else \
        fetch_asset "${VELOX_URL_LINUX_ARM64}" "$LINUX_ARM64_V" linux-arm64 \
                    /opt/velociraptor/linux/velociraptor_client_arm64 false "${VELOX_SHA256_LINUX_ARM64}"; \
      fi; \
    done; \
    fetch_asset "${VELOX_URL_LINUX_AMD64_MUSL}" "$LINUX_AMD64_MUSL_V" linux-amd64-musl \
                /opt/velociraptor/linux/velociraptor_client_amd64_musl false "${VELOX_SHA256_LINUX_AMD64_MUSL}"; \
    fetch_asset "${VELOX_URL_DARWIN_AMD64}" "$DARWIN_AMD64_V" darwin-amd64 \
                /opt/velociraptor/mac/velociraptor_client_amd64 false "${VELOX_SHA256_DARWIN_AMD64}"; \
    fetch_asset "${VELOX_URL_DARWIN_ARM64}" "$DARWIN_ARM64_V" darwin-arm64 \
                /opt/velociraptor/mac/velociraptor_client_arm64 false "${VELOX_SHA256_DARWIN_ARM64}"; \
    fetch_asset "${VELOX_URL_WINDOWS_EXE}" "$WINDOWS_EXE_V" windows-amd64.exe \
                /opt/velociraptor/windows/velociraptor_client.exe false "${VELOX_SHA256_WINDOWS_EXE}"; \
    fetch_asset "${VELOX_URL_WINDOWS_MSI}" "$WINDOWS_MSI_V" windows-amd64.msi \
                /opt/velociraptor/windows/velociraptor_client.msi false "${VELOX_SHA256_WINDOWS_MSI}"; \
    for f in /opt/velociraptor/linux/* /opt/velociraptor/mac/* /opt/velociraptor/windows/*.exe; do \
      if [ -s "$f" ]; then chmod +x "$f"; fi; \
    done; \
    # Bake checksums next to each present binary so the entrypoint can
    # detect upstream binary changes across rebuilds.
    for f in /opt/velociraptor/linux/* /opt/velociraptor/mac/* /opt/velociraptor/windows/*; do \
      case "$f" in *.sha256) continue ;; esac; \
      if [ -s "$f" ]; then sha256sum "$f" | awk '{print $1}' > "${f}.sha256"; fi; \
    done; \
    echo "Downloads done."

COPY --from=sigma /out/ /opt/velociraptor/artifacts/

# Bundle official custom definitions as immutable, verified build inputs.
# The frontend loads this directory on every start via --definitions.
# All bundled definitions are verified together; two known upstream lint
# issues are tolerated, matched exactly, while any other error fails the build:
#   * v0.77.3 requires artifacts calling tempfile() to declare FILESYSTEM_WRITE;
#     the Triage definitions do not yet (they load and run fine).
#   * `verify` cannot lex the 1.1 MB base64 rules literal embedded in
#     Windows.Hayabusa.Rules; the server parses and runs it fine (the CI
#     smoke test checks the server loads it).
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
  if ! /opt/velociraptor/linux/velociraptor artifacts verify --builtin \
      /opt/velociraptor/artifacts/*.yaml \
      > /tmp/verify.log 2>&1; then \
    cut -c1-400 /tmp/verify.log; \
    if grep -E '^ERROR: ' /tmp/verify.log \
        | grep -v -E "^ERROR: (Linux\.Triage\.UAC|Windows\.Triage\.Targets): \(0,0\) required_permissions: Add FILESYSTEM_WRITE to artifact's required_permissions or implied_permissions fields$" \
        | grep -v -E '^ERROR: artifact_set: While parsing source query : de\(string=\|"H4sI[A-Za-z0-9+/]*: 1:[0-9]+: lexer: invalid input text "\\"H4sI[A-Za-z0-9+/]*\.\.\.": name: Windows\.Hayabusa\.Rules$' \
        | grep -q .; then \
      echo "FATAL: bundled artifact verification failed" >&2; \
      exit 1; \
    fi; \
    if ! grep -q -E '^ERROR: ' /tmp/verify.log; then \
      echo "FATAL: artifact verification failed without reporting errors" >&2; \
      exit 1; \
    fi; \
    echo "WARNING: tolerated known upstream lint issues (Triage FILESYSTEM_WRITE, Hayabusa rules literal)"; \
  fi; \
  rm -f /tmp/verify.log

WORKDIR /velociraptor

# Small, frequently changing inputs last so the layers above stay cached.
COPY --chmod=0755 entrypoint /entrypoint
COPY --chmod=0755 healthcheck /usr/local/bin/velox-healthcheck
COPY --chmod=0755 artifacts-sync /usr/local/bin/velox-artifacts-sync

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD ["/usr/local/bin/velox-healthcheck"]

ARG GIT_COMMIT
ARG BUILD_DATE
ARG BASE_IMAGE=ubuntu:26.04
ENV VELOX_VERSION=${VELOX_VERSION} \
    TARGETARCH=${TARGETARCH} \
    GIT_COMMIT=${GIT_COMMIT:-unknown} \
    BUILD_DATE=${BUILD_DATE:-unknown} \
    BASE_IMAGE=${BASE_IMAGE} \
    VELOX_TRIAGE_SOURCE_COMMIT=${TRIAGE_SOURCE_COMMIT} \
    VELOX_SIGMA_SOURCE_COMMIT=${SIGMA_SOURCE_COMMIT}

ENTRYPOINT ["/entrypoint"]
