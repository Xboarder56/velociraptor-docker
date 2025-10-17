# Use a default but allow override
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG VELOX_VERSION
ARG TARGETARCH
ARG GIT_COMMIT
ARG BUILD_DATE
ARG BASE_IMAGE

LABEL org.opencontainers.image.title="Velociraptor"
LABEL org.opencontainers.image.version="${VELOX_VERSION}"
LABEL org.opencontainers.image.description="Velociraptor server in a Docker container"
LABEL org.opencontainers.image.source="https://github.com/Xboarder56/velociraptor-docker"
LABEL org.opencontainers.image.base="${BASE_IMAGE}"

ENV DEBIAN_FRONTEND=noninteractive \
    VELOX_VERSION=${VELOX_VERSION} \
    TARGETARCH=${TARGETARCH} \
    GIT_COMMIT=${GIT_COMMIT:-unknown} \
    BUILD_DATE=${BUILD_DATE:-unknown} \
    BASE_IMAGE=${BASE_IMAGE}

COPY ./entrypoint /entrypoint
RUN chmod +x /entrypoint && \
    apt-get update && \
    apt-get install -y --no-install-recommends curl jq rsync ca-certificates && \
    mkdir -p /opt/velociraptor/linux /opt/velociraptor/mac /opt/velociraptor/windows && \
    rm -rf /var/lib/apt/lists/*

# Download Velociraptor Clients + Server Binary depending on TARGETARCH
RUN set -eux; \
    VELOX_RELEASE="${VELOX_VERSION%.*}"; \
    case "${TARGETARCH}" in \
      amd64) SERVER_BIN="velociraptor-${VELOX_VERSION}-linux-amd64" ;; \
      arm64) SERVER_BIN="velociraptor-${VELOX_VERSION}-linux-arm64" ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" && exit 1 ;; \
    esac; \
    SERVER_URL="https://github.com/Velocidex/velociraptor/releases/download/${VELOX_RELEASE}/${SERVER_BIN}"; \
    LINUX_CLIENT_AMD64="https://github.com/Velocidex/velociraptor/releases/download/${VELOX_RELEASE}/velociraptor-${VELOX_VERSION}-linux-amd64"; \
    LINUX_CLIENT_ARM64="https://github.com/Velocidex/velociraptor/releases/download/${VELOX_RELEASE}/velociraptor-${VELOX_VERSION}-linux-arm64"; \
    MAC_CLIENT_ARM64="https://github.com/Velocidex/velociraptor/releases/download/${VELOX_RELEASE}/velociraptor-${VELOX_VERSION}-darwin-arm64"; \
    MAC_CLIENT_AMD64="https://github.com/Velocidex/velociraptor/releases/download/${VELOX_RELEASE}/velociraptor-${VELOX_VERSION}-darwin-amd64"; \
    WINDOWS_EXE="https://github.com/Velocidex/velociraptor/releases/download/${VELOX_RELEASE}/velociraptor-${VELOX_VERSION}-windows-amd64.exe"; \
    WINDOWS_MSI="https://github.com/Velocidex/velociraptor/releases/download/${VELOX_RELEASE}/velociraptor-${VELOX_VERSION}-windows-amd64.msi"; \
    echo "Downloading server binary: ${SERVER_BIN}"; \
    curl -fL "$SERVER_URL" -o /opt/velociraptor/linux/velociraptor && chmod +x /opt/velociraptor/linux/velociraptor; \
    [ -x /opt/velociraptor/linux/velociraptor ] || (echo "Server binary missing!" && exit 1); \
    echo "Downloading client binaries..."; \
    curl -fL "$LINUX_CLIENT_AMD64" -o /opt/velociraptor/linux/velociraptor_client_amd64 || true; \
    curl -fL "$LINUX_CLIENT_ARM64" -o /opt/velociraptor/linux/velociraptor_client_arm64 || true; \
    curl -fL "$MAC_CLIENT_AMD64" -o /opt/velociraptor/mac/velociraptor_client_amd64 || true; \
    curl -fL "$MAC_CLIENT_ARM64" -o /opt/velociraptor/mac/velociraptor_client_arm64 || true; \
    curl -fL "$WINDOWS_EXE" -o /opt/velociraptor/windows/velociraptor_client.exe || true; \
    curl -fL "$WINDOWS_MSI" -o /opt/velociraptor/windows/velociraptor_client.msi || true; \
    echo "All binaries downloaded successfully."

WORKDIR /velociraptor
ENTRYPOINT ["/entrypoint"]
