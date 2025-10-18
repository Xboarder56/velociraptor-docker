**GitHub Repository:** [**github.com/Xboarder56/velociraptor-docker**](https://github.com/Xboarder56/velociraptor-docker)

---

# Velociraptor (Server) in Docker

Run the [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor) server in a container with sensible defaults, HTTPS, and prebuilt client repacks.

- **Architectures:** `linux/amd64`, `linux/arm64`
- **Ports:** `8000` (client/ingest), `8889` (GUI), `8001` (gRPC API), `8003` (Prometheus)
- **Data dir:** mount `/velociraptor` to persist config, keys, artifacts, and repacked clients
- **TLS:** self-signed cert generated on first run (you can rotate later)

On start, the container prints a small build banner (version, arch, base image, git commit, build date) so you can confirm what you pulled.

---

## Quick Start

```bash
docker run -it --rm \
  -p 8000:8000 -p 8889:8889 -p 8001:8001 -p 8003:8003 \
  -v $PWD/velodata:/velociraptor \
  xboarder56/velociraptor:latest
```

Open [**https://localhost:8889**](https://localhost:8889) (accept the self-signed cert) and log in with the bootstrap credentials below (you should change them right away).

---

## Runtime Configuration (Environment Variables)

These **variables are read at container start**—no image rebuilds needed.

| Variable                          | Purpose                                                                | Default                         |
| --------------------------------- | ---------------------------------------------------------------------- | ------------------------------- |
| `VELOX_DEFAULT_USER`              | Initial GUI admin username                                             | `admin`                         |
| `VELOX_DEFAULT_PASSWORD`          | Initial GUI admin password                                             | `changeme`                      |
| `VELOX_DEFAULT_USER_ROLE`         | Role for the bootstrap user                                            | `administrator`                 |
| **File System**                   |                                                                        |                                 |
| `VELOX_FILESTORE_DIRECTORY`       | Root of Velociraptor filestore (collections, uploads)                  | `/velociraptor/file_store`      |
| `VELOX_CLIENT_DIR`                | Directory where repacked clients are stored                            | `/velociraptor/client_bundles}` |
| **Client/Frontend Configuration** |                                                                        |                                 |
| `VELOX_FRONTEND_HOSTNAME`         | Public hostname for clients (builds client URL)                        | `localhost`                     |
| `VELOX_FRONTEND_PORT`             | Public-facing port for clients (builds client URL)                     | `8000`                          |
| `VELOX_FRONTEND_SERVER_SCHEME`    | Public scheme (`https`/`http`) for client URLs                         | `https`                         |
| `VELOX_FRONTEND_SERVER_URL`       | Full override for the client URL (e.g., `https://ingest.example.com/`) | derived from components         |
| `VELOX_SERVER_URL` (legacy)       | Alias for `VELOX_FRONTEND_SERVER_URL`. Use new variable.               | `n/a`                           |
| **GUI/Admin Configuration**       |                                                                        |                                 |
| `VELOX_GUI_HOSTNAME`              | Public hostname for the admin GUI (builds GUI URL)                     | `localhost` (or client host)    |
| `VELOX_GUI_PORT`                  | Public-facing port for the admin GUI (builds GUI URL)                  | `8889`                          |
| `VELOX_GUI_SCHEME`                | Public scheme (`http` or `https` for GUI URL                           | `https`                         |
| `VELOX_GUI_URL`                   | Full override for the GUI URL (e.g., `https://admin.example.com/`)     | derived from components         |
| **Internal Ports**                |                                                                        |                                 |
| `VELOX_API_PORT`                  | gRPC API port                                                          | `8001`                          |
| `VELOX_MONITORING_PORT`           | Metrics port                                                           | `8003`                          |
| **Logging**                       |                                                                        |                                 |
| `VELOX_START_SERVER_VERBOSE`      | `true` to enable verbose (`-v`) server logs                            | *(off)*                         |
| `VELOX_LOG_DIR`                   | Where component logs write inside container                            | `.`                             |
| `VELOX_DEBUG_DISABLED`            | Disable DEBUG in component logs                                        | `true`                          |

**Persistent paths (mount a volume):**

- `/velociraptor/server.config.yaml` — server config (auto-generated)
- `/velociraptor/client.config.yaml` — client config
- `/velociraptor/client_bundles/` — repacked client binaries (.deb/.rpm/.exe/.msi)

---

## Common Run Examples

### 1) Run quietly (INFO mode)

This overrides the default, which is to run with verbose (DEBUG) logs.

```bash
docker run -it --rm \
  -p 8000:8000 -p 8889:8889 -p 8001:8001 -p 8003:8003 \
  -v $PWD/velodata:/velociraptor \
  -e VELOX_DEFAULT_USER=admin -e VELOX_DEFAULT_PASSWORD='S3cure!' \
  -e VELOX_START_SERVER_VERBOSE=false \
  xboarder56/velociraptor:latest
```

### 2) Set the public URL clients should use

```bash
docker run -it --rm \
  -e VELOX_FRONTEND_HOSTNAME=velociraptor.example.com \
  -e VELOX_FRONTEND_PORT=443 \
  -e VELOX_FRONTEND_SERVER_SCHEME=https \
  -p 443:8000 -p 8889:8889 \
  -v $PWD/velodata:/velociraptor \
  xboarder56/velociraptor:latest
```

### 3) Use different public URLs for Client and GUI

```bash
docker run -it --rm \
  -e VELOX_FRONTEND_SERVER_URL=https://ingest.example.com:8000/ \
  -e VELOX_GUI_URL=https://admin.example.com:8889/ \
  -p 8000:8000 -p 8889:8889 \
  -v $PWD/velodata:/velociraptor \
  xboarder56/velociraptor:latest
```

---

## Docker Compose

```yaml
services:
  velociraptor:
    image: xboarder56/velociraptor:latest
    restart: unless-stopped
    environment:
      VELOX_DEFAULT_USER: admin
      VELOX_DEFAULT_PASSWORD: "S3cure!"
      VELOX_FRONTEND_HOSTNAME: velociraptor.example.com
      VELOX_START_SERVER_VERBOSE: "false"
    ports:
      - "8000:8000"   # client/ingest
      - "8889:8889"   # GUI
      - "8001:8001"   # gRPC API
      - "8003:8003"   # Metrics
    volumes:
      - ./velodata:/velociraptor
```

---

## What to Expect on First Run

- The entrypoint generates a secure **server.config.yaml** and a **client.config.yaml**.
- Clients for Linux (amd64 + arm64), macOS (amd64 + arm64), and Windows (exe + msi) are **repacked** into `/velociraptor/client_bundles/` with your server URL.
- You’ll see logs like:
  - `GUI is ready to handle TLS requests on https://localhost:8889/`
  - `Frontend is ready to handle client TLS requests at https://localhost:8000/`

---

## Client Binaries

After startup, check `./velodata/client_bundles/` for repacked binaries:

- **Linux:** `.deb` and `.rpm` packages for amd64 and arm64
- **macOS:** repacked executables for amd64 and arm64
- **Windows:** `.exe` and `.msi`

If a specific upstream client binary isn’t available, the repack step is skipped (you’ll see a log message).

---

## Security Notes

- **Change the default credentials** via `VELOX_USER` / `VELOX_PASSWORD` on first run.
- TLS is **self-signed** by default; rotate keys/certificates as needed from the server.
- Expose GUI/API only where appropriate; consider a reverse proxy or firewall rules.

---

## Troubleshooting

- Seeing `[DEBUG] FlowStorageManager housekeeping run`?\
  You likely set `VELOX_START_SERVER_VERBOSE=true` (adds `-v`). Remove it to suppress DEBUG.
- Ports already in use? Map them as needed: `-p 443:8000` and set `VELOX_FRONTEND_PORT=443`.

---

## Tags

- `:latest` — current release
- `:<version>` — pinned image matching the bundled Velociraptor release (e.g., `0.75.3`)
- Multi-arch manifests are published for **amd64** and **arm64**

---

### 🧩 About This Fork

This repository is a fork of [weslambert/velociraptor-docker](https://github.com/weslambert/velociraptor-docker), originally created by **Wes Lambert**.  
It aims to maintain compatibility with the latest [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor) releases while providing additional configuration options and deployment improvements for Docker environments.

All credit for the foundational work goes to Wes Lambert — this fork primarily adds quality-of-life enhancements, updated configurations, and maintenance updates.

---

**Maintained by:** [Xboarder56](https://github.com/Xboarder56)  
**Upstream project:** [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor)