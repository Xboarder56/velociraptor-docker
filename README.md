**GitHub Repository:** [**github.com/Xboarder56/velociraptor-docker**](https://github.com/Xboarder56/velociraptor-docker)

---

# Velociraptor (Server) in Docker

Run the [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor) server in a container with sensible defaults, HTTPS, prebuilt client repacks, and bundled Triage, Sigma and Hayabusa artifacts.

- **Architectures:** `linux/amd64`, `linux/arm64`
- **Ports:** `8000` (client/ingest), `8889` (GUI), `8001` (gRPC API), `8003` (Prometheus)
- **Data dir:** mount `/velociraptor` to persist config, keys, artifacts, and repacked clients
- **TLS:** self-signed cert generated on first run, rotated automatically 30 days before it expires
- **Non-root:** the entrypoint prepares the volume, then runs the server as uid/gid `10001`
- **Verified inputs:** every Velociraptor binary is checked against its pinned SHA-256 and its Velocidex release signature at build time

On start, the container prints a small build banner (version, arch, base image, git commit, build date, and the pinned Triage and Sigma commits) so you can confirm what you pulled.

---

## Quick Start

```bash
docker run -it --rm \
  -p 8000:8000 -p 8889:8889 -p 127.0.0.1:8001:8001 -p 127.0.0.1:8003:8003 \
  -v $PWD/velodata:/velociraptor \
  docker.io/xboarder56/velociraptor:latest
```

Open [**https://localhost:8889**](https://localhost:8889) (accept the self-signed cert) and log in with the bootstrap credentials below (you should change them right away).

The same command works with Podman by replacing `docker` with `podman`; see [Podman](#podman) for the healthcheck flag and rootless notes. The fully qualified `docker.io/...` image name avoids short-name registry ambiguity. On SELinux-enforcing hosts, label a bind mount for the container by using `-v "$PWD/velodata:/velociraptor:Z"`.

---

## Runtime Configuration (Environment Variables)

These **variables are read at container start**—no image rebuilds needed.

| Variable | Purpose | Default |
| -------- | ------- | ------- |
| `VELOX_CONFIG_MODE` | Config ownership: `reconcile`, `generated`, or `external` | `reconcile` |
| `VELOX_CONFIG_FILE` | Server config path; required in `external` mode | `server.config.yaml` |
| **Bootstrap user** | | |
| `VELOX_DEFAULT_USER` | Initial GUI admin username | `admin` |
| `VELOX_DEFAULT_PASSWORD` | Initial GUI admin password | `changeme` |
| `VELOX_DEFAULT_PASSWORD_FILE` | Read the initial admin password from a mounted secret file | unset |
| `VELOX_DEFAULT_USER_ROLE` | Role for the bootstrap user (`administrator`, `org_admin`, `reader`, `analyst`, `investigator`, `artifact_writer`, `api`) | `administrator` |
| **File system** | | |
| `VELOX_FILESTORE_DIRECTORY` | Root of the filestore (collections, uploads); first run only | `./filestore` (`/velociraptor/filestore`) |
| `VELOX_CLIENT_DIR` | Where repacked clients are written | `/velociraptor/client_bundles` |
| `VELOX_EXTRA_ARTIFACTS_DIR` | Extra artifact definitions (`*.yaml`/`*.yml`) loaded with the bundled ones | `/velociraptor/artifacts` |
| `VELOX_ARTIFACTS_MANIFEST` | Declarative list of artifacts to install (by URL + SHA-256) and to disable; see [Managing artifacts](#managing-artifacts) | `/velociraptor/artifacts.yaml` |
| `VELOX_DISABLE_ARTIFACTS` | Comma/space-separated artifact names not to load (bundled or custom) | unset |
| `VELOX_ARTIFACTS_STRICT` | `false` starts anyway when a manifest entry fails (download, checksum), skipping it | `true` |
| **Client / frontend (public side)** | | |
| `VELOX_FRONTEND_HOSTNAME` | Public hostname or IP clients connect to. Optional; without it clients use `localhost` and the log warns | `localhost` |
| `VELOX_FRONTEND_PORT` | Public port in the client URL (e.g. `443` behind a proxy or with `-p 443:8000`) | the listen port |
| `VELOX_FRONTEND_SERVER_SCHEME` | Scheme in the client URL | `https` |
| `VELOX_FRONTEND_SERVER_URL` | Full client URL override (e.g. `https://ingest.example.com/`); a missing trailing `/` is added | derived |
| `VELOX_SERVER_URL` (legacy) | Alias for `VELOX_FRONTEND_SERVER_URL` | unset |
| **GUI (public side)** | | |
| `VELOX_GUI_HOSTNAME` | Public hostname for the GUI URL | `localhost` (reconcile: current, or the client host) |
| `VELOX_GUI_PORT` | Public port in the GUI URL | the listen port |
| `VELOX_GUI_SCHEME` | Scheme in the GUI URL | `https` |
| `VELOX_GUI_URL` | Full GUI URL override; `/app/index.html` is appended if missing | derived |
| **Listening ports (inside the container)** | | |
| `VELOX_FRONTEND_BIND_PORT` | Port the client frontend listens on | `8000` |
| `VELOX_GUI_BIND_PORT` | Port the GUI listens on | `8889` |
| `VELOX_API_PORT` | gRPC API port | `8001` |
| `VELOX_MONITORING_PORT` | Prometheus metrics port | `8003` |
| **Process** | | |
| `VELOX_UID` / `VELOX_GID` | Account the server runs as (e.g. your host user's ids for bind mounts) | `10001` / `10001` |
| `VELOX_RUN_AS_ROOT` | `true` keeps the server running as root (previous behavior) | `false` |
| `VELOX_CERT_RENEW_DAYS` | Rotate the frontend certificate when it expires within this many days | `30` |
| **Logging** | | |
| `VELOX_START_SERVER_VERBOSE` | `true` runs the server with `-v` (DEBUG logs); `false` for INFO | `true` |
| `VELOX_LOG_DIR` | Component log directory | `./logs` (`/velociraptor/logs`) |
| `VELOX_DEBUG_DISABLED` | Disable DEBUG in component logs | `true` |

Public settings only change the URLs written into client configs and the GUI link. The server keeps listening on the `*_BIND_PORT` values, so a reverse proxy URL such as `https://ingest.example.com/` never moves the listener away from the port you published. In `reconcile` mode, existing listen ports change only when a `*_BIND_PORT` variable is set.

**Persistent paths (mount a volume):**

- `/velociraptor/server.config.yaml` — server config (auto-generated, mode `0600`: it holds the CA and server private keys)
- `/velociraptor/client.config.yaml` — client config
- `/velociraptor/client_bundles/` — repacked client binaries (.deb/.rpm/.exe/.msi), world-readable for easy copying
- `/velociraptor/artifacts/` — optional: your own artifact definitions
- `/velociraptor/artifacts.yaml` — optional: the artifact manifest (downloads are cached in `/velociraptor/.artifact-cache/`)

### Configuration ownership modes

The default remains `reconcile`, preserving the behavior of previous image versions and existing installations.

| Mode | Behavior |
| ---- | -------- |
| `reconcile` | Generate a missing config, then apply explicitly supplied environment settings on every start. Automatic certificate rotation remains enabled. |
| `generated` | Generate a missing config, but treat an existing config as authoritative instead of reconciling environment settings. Automatic certificate rotation remains enabled. |
| `external` | Require `VELOX_CONFIG_FILE` to reference an existing readable config. The entrypoint never generates, edits, backs up, or rotates this file. Bootstrap-user creation is skipped. |

Use an external config with a read-only bind mount:

```bash
docker run -it --rm \
  -e VELOX_CONFIG_MODE=external \
  -e VELOX_CONFIG_FILE=/config/server.config.yaml \
  -v "$PWD/server.config.yaml:/config/server.config.yaml:ro" \
  -v "$PWD/velodata:/velociraptor" \
  -p 8000:8000 -p 8889:8889 -p 127.0.0.1:8001:8001 -p 127.0.0.1:8003:8003 \
  docker.io/xboarder56/velociraptor:latest
```

If the server account cannot read the external file (for example a root-owned `0600` file), the entrypoint gives the server a private copy at start; the original is never modified.

Because `external` mode cannot replace its configuration, certificate/key rotation must be handled by the external config owner. Generated client configuration and client bundles are still written beneath `/velociraptor`.

### Bootstrap password secrets

`VELOX_DEFAULT_PASSWORD_FILE` follows the Docker/Podman `_FILE` convention. It is read only when the bootstrap user is created: on first start, or when an existing datastore has no users at all (for example after an interrupted first start with an older image). The file must be readable and non-empty, and setting both password variables during initialization is an error.

```yaml
secrets:
  velociraptor_admin_password:
    file: ./secrets/admin-password

services:
  velociraptor:
    image: docker.io/xboarder56/velociraptor:latest
    environment:
      VELOX_DEFAULT_PASSWORD_FILE: /run/secrets/velociraptor_admin_password
    secrets:
      - velociraptor_admin_password
    volumes:
      - ./velodata:/velociraptor
```

The secret value is not placed in the container environment or retained by the server process. The secret-file path remains visible in container metadata. Direct `VELOX_DEFAULT_PASSWORD` remains supported for compatibility, but direct environment values are visible through container inspection.

---

## Common Run Examples

### 1) Run quietly (INFO mode)

This overrides the default, which is to run with verbose (DEBUG) logs.

```bash
docker run -it --rm \
  -p 8000:8000 -p 8889:8889 -p 127.0.0.1:8001:8001 -p 127.0.0.1:8003:8003 \
  -v $PWD/velodata:/velociraptor \
  -e VELOX_DEFAULT_USER=admin -e VELOX_DEFAULT_PASSWORD='S3cure!' \
  -e VELOX_START_SERVER_VERBOSE=false \
  docker.io/xboarder56/velociraptor:latest
```

### 2) Set the public URL clients should use

Here clients reach the host on port 443, which is mapped to the frontend's default listen port 8000:

```bash
docker run -it --rm \
  -e VELOX_FRONTEND_HOSTNAME=velociraptor.example.com \
  -e VELOX_FRONTEND_PORT=443 \
  -e VELOX_FRONTEND_SERVER_SCHEME=https \
  -p 443:8000 -p 8889:8889 \
  -v $PWD/velodata:/velociraptor \
  docker.io/xboarder56/velociraptor:latest
```

### 3) Use different public URLs for Client and GUI (reverse proxy)

```bash
docker run -it --rm \
  -e VELOX_FRONTEND_SERVER_URL=https://ingest.example.com/ \
  -e VELOX_GUI_URL=https://admin.example.com/ \
  -p 8000:8000 -p 8889:8889 \
  -v $PWD/velodata:/velociraptor \
  docker.io/xboarder56/velociraptor:latest
```

### 4) Load your own artifacts

See [Managing artifacts](#managing-artifacts).

---

## Docker Compose

The repository's [`docker-compose.yaml`](docker-compose.yaml) is the recommended starting point. It adds `init: true`, `no-new-privileges`, a minimal capability set, a pids limit, a memory limit (`VELOX_MEM_LIMIT`, default `4g`), and a commented Docker secrets example. A minimal version:

```yaml
services:
  velociraptor:
    image: docker.io/xboarder56/velociraptor:latest
    restart: unless-stopped
    environment:
      VELOX_CONFIG_MODE: reconcile # backward-compatible default
      VELOX_DEFAULT_USER: admin
      VELOX_DEFAULT_PASSWORD: "S3cure!"
      VELOX_FRONTEND_HOSTNAME: velociraptor.example.com
      VELOX_START_SERVER_VERBOSE: "false"
    ports:
      - "8000:8000"   # client/ingest
      - "8889:8889"   # GUI
      - "127.0.0.1:8001:8001"   # gRPC API (loopback only)
      - "127.0.0.1:8003:8003"   # Metrics (unauthenticated; loopback only)
    volumes:
      - ./velodata:/velociraptor
```

---

## What to Expect on First Run

- The entrypoint generates a secure **server.config.yaml** (moved into place only after the admin user exists, so an interrupted first start leaves nothing half-done) and a **client.config.yaml**.
- Clients for Linux (amd64 + arm64, plus a static amd64 musl build), macOS (amd64 + arm64), and Windows (exe + msi) are **repacked** into `/velociraptor/client_bundles/` with your server URL.
- The data volume is handed to the server account (uid `10001`), then the server starts without root.
- With verbose logs (the default) you’ll see lines like:
  - `GUI is ready to handle TLS requests on https://localhost:8889/`
  - `Frontend is ready to handle client TLS requests at https://localhost:8000/`

---

## Client Binaries

After startup, check `./velodata/client_bundles/` for repacked binaries:

- **Linux:** repacked executables for amd64 and arm64 (`velociraptor_client_<arch>_repacked`), a statically linked amd64 musl build (`velociraptor_client_amd64_musl_repacked`) for hosts with an old or missing glibc (Alpine, older RHEL/CentOS, appliances, minimal containers), and `.deb`/`.rpm` packages for both amd64 and arm64
- **macOS:** repacked executables for amd64 and arm64
- **Windows:** `.exe` and `.msi`

If a specific upstream client binary isn’t available, the repack step is skipped (you’ll see a log message).

---

## Bundled Artifacts

Every image includes these official Velocidex artifacts, ready to collect or hunt with from the GUI:

**[Triage](https://triage.velocidex.com/docs/triage_artifacts/)** (file collection):

- `Windows.Triage.Targets` — Windows triage driven by the [KapeFiles](https://github.com/EricZimmerman/KapeFiles) target definitions
- `Linux.Triage.UAC` — Linux triage driven by the [UAC (Unix-like Artifacts Collector)](https://github.com/tclahr/uac) artifact definitions

**[Sigma and Hayabusa](https://sigma.velocidex.com/)** (detection):

- `Windows.Hayabusa.Rules` — the [Hayabusa](https://github.com/Yamato-Security/hayabusa) Sigma ruleset compiled for Velociraptor: hunt Windows event logs for suspicious activity
- `Windows.Hayabusa.Monitoring` — the same rules as a client event (real-time) artifact
- `Windows.Sigma.Triage`, `Linux.Sigma.Triage`, `MacOS.Sigma.Triage` — curated Sigma triage rules per platform
- Their base artifacts: `Windows.Sigma.Base`, `Windows.Sigma.BaseEvents`, `Windows.Sigma.BaseVQL`, `Linux.Sigma.Base`, `MacOS.Sigma.BaseVQL`

All definitions are pinned to immutable upstream commits (`artifacts.lock`), verified by SHA-256 during the build, checked with the bundled Velociraptor binary, and loaded on every server start (CI also checks that the running server has every one of them). The daily upstream workflow tracks both projects. It opens a revision PR when the definitions really change; rebuilds that only update an embedded build stamp are ignored.

Two known upstream lint issues are tolerated at build time, each matched exactly: the Triage artifacts don't yet declare `FILESYSTEM_WRITE`, and `artifacts verify` cannot lex the 1.1 MB compressed rule literal in `Windows.Hayabusa.Rules`. The server loads and runs both fine.

To bundle more artifacts from the Sigma pack, add `<file in the pack>:<artifact name>` entries to `SIGMA_ARTIFACTS` in `artifacts.lock` (file names as in [`Velociraptor.Sigma.Artifacts.zip`](https://sigma.velocidex.com/)). For anything else, use `./velodata/artifacts/` (see example 4).

### Managing artifacts

The server loads a set of artifact definitions that is **rebuilt on every start** from three sources. A later source replaces an artifact of the same name from an earlier one:

1. **Bundled:** the artifacts listed above.
2. **Your directory:** every `*.yaml`/`*.yml` in `./velodata/artifacts/` (`VELOX_EXTRA_ARTIFACTS_DIR`).
3. **The manifest:** artifacts declared in `./velodata/artifacts.yaml` (`VELOX_ARTIFACTS_MANIFEST`), downloaded and verified.

Then everything named under `disable:` (or in `VELOX_DISABLE_ARTIFACTS`) is removed, bundled ones included. Because the set is rebuilt each time, removing a file or a manifest line and restarting removes that artifact.

```yaml
# ./velodata/artifacts.yaml
artifacts:
  # A single definition
  - url: https://raw.githubusercontent.com/example/artifacts/<commit>/Custom.Windows.Foo.yaml
    sha256: 4144a5ec6fda351bacace29b17b4a55f830e99fbb296010badf767a2bb31c0ba
  # A zip pack: take only some of its artifacts (omit `include` to take all)
  - url: https://example.com/packs/detections-v3.zip
    sha256: 0c17f2233bb3b81430305c11e659c1f81bb53531e04557aaca5a1ba55f4f0e81
    include: [Custom.Linux.Bar, Custom.Linux.Baz]
disable:
  - Windows.Hayabusa.Monitoring   # bundled, not wanted here
```

- **Checksums are required.** Get one with `curl -fsSL <url> | sha256sum`. Pin URLs to a commit or release so the checksum stays valid.
- **Downloads are cached** by checksum in `/velociraptor/.artifact-cache/`, so restarts work offline and don't download again.
- **A failed entry stops the start** (wrong checksum, download error, or a file that isn't an artifact), so the server never silently runs without something you declared. With `VELOX_ARTIFACTS_STRICT=false` a failing entry is skipped with a warning and the rest of the manifest, including `disable:`, still applies (unknown top-level keys are also just warned about). A manifest that isn't valid YAML can't be read at all: strict stops the start, lenient starts without it.
- **The start-up log shows what happened:** what was loaded from each source, what replaced what, and what was disabled. A name in `disable:` that doesn't exist only produces a warning.
- **Scope:** this manages the artifacts loaded from files. Velociraptor's built-in artifacts can't be disabled this way. Artifacts you create or import in the GUI are stored in the datastore and managed there.

---

## Podman

The image works with Docker and with Podman, rootful or rootless. CI runs the end-to-end image validation (`ci-image-validation.sh`) under rootless Podman for every pull request and push to `main`.

```bash
podman run -d --name velociraptor \
  --health-cmd /usr/local/bin/velox-healthcheck --health-interval 30s \
  -p 8000:8000 -p 8889:8889 -p 127.0.0.1:8001:8001 -p 127.0.0.1:8003:8003 \
  -v velodata:/velociraptor \
  -e VELOX_DEFAULT_PASSWORD='S3cure!' \
  docker.io/xboarder56/velociraptor:latest
```

- **Healthcheck:** Podman ignores `HEALTHCHECK` in OCI-format images, so pass `--health-cmd` as above. The repository's `docker-compose.yaml` declares the healthcheck itself, so `podman compose` gets it too.
- **Rootless:** the container's root is your user, and uid `10001` maps into your subordinate id range. Named volumes just work. For a bind mount, the host directory ends up owned by that subordinate id; use `podman unshare ls -l ./velodata` to look inside, or set `VELOX_RUN_AS_ROOT=true` so files stay owned by your own user (in rootless Podman, the container's root is you).
- **Don't use `--userns=keep-id` or `--user`.** The entrypoint must start as (namespaced) root to prepare the volume before dropping privileges.
- **SELinux:** add `:Z` to bind mounts (`-v ./velodata:/velociraptor:Z`).
- **Ports below 1024:** rootless Podman can't publish them unless the host allows it (`net.ipv4.ip_unprivileged_port_start`); publish a high port instead (`-p 8443:8000`).

---

## Security Notes

- **Change the default credentials** on first run; prefer `VELOX_DEFAULT_PASSWORD_FILE` so the password is not stored in container metadata. (While the bootstrap user is created, the password is briefly on the `velociraptor user add` command line: Velociraptor cannot read it from stdin.)
- The server runs as an unprivileged user; `server.config.yaml` and its backups are `0600`.
- Release binaries are verified against pinned SHA-256 values and the Velocidex release signing key (`0572 F28B 4EF1 9A04 3F4C BBE0 B22A 7FB1 9CB6 CFA1`, `keys/velocidex-release.asc`).
- TLS is **self-signed** by default. The frontend certificate is rotated automatically before it expires (`VELOX_CERT_RENEW_DAYS`); the CA is kept, so clients keep trusting the server.
- Expose GUI/API only where appropriate; consider a reverse proxy or firewall rules.
- The examples publish the gRPC API (`8001`) and Prometheus metrics (`8003`) on `127.0.0.1` only. The metrics endpoint has no authentication; publish it more widely only behind a firewall or to a trusted scrape network.

---

## Troubleshooting

- Too many `[DEBUG]` lines? Verbose logging is the default; set `VELOX_START_SERVER_VERBOSE=false`.
- Ports already in use? Map them as needed, e.g. `-p 443:8000`, and set `VELOX_FRONTEND_PORT=443` so clients use the public port.
- `Permission denied` on a bind mount after upgrading? The volume now belongs to uid `10001`. Set `VELOX_UID`/`VELOX_GID` to your host user's ids, or `VELOX_RUN_AS_ROOT=true` for the old behavior.
- GUI pages load but every action fails with HTTP 503 (older images, configs created before this fix)? The GUI calls its own API through `API.hostname`, which defaulted to the public hostname. New configs, and `reconcile`-mode configs on start, set it to `127.0.0.1`; for `generated`/`external` configs set `API.hostname: 127.0.0.1` yourself.

---

## Upgrading from earlier images

- Existing volumes keep working: on first start the entrypoint changes ownership of the data directory to the server account and tightens `server.config.yaml` to `0600`. Large datastores take a moment the first time; later starts only touch files with the wrong owner.
- `VELOX_FRONTEND_PORT` and `VELOX_GUI_PORT` now only set the public ports in URLs (as documented). If you used them to change the port the server *listens* on, set `VELOX_FRONTEND_BIND_PORT`/`VELOX_GUI_BIND_PORT` instead. Existing listen ports in a persisted config are left as they are.
- `./velociraptor` in the volume is now a link to the image's binary.
- The bundled Sigma and Hayabusa artifacts appear automatically; nothing to configure.

---

## Tags

- `:latest` — the newest Velociraptor version released here (never moves back to an older version)
- `:<velociraptor-version>` — e.g. `:0.77.3`. Follows image revisions of that upstream release.
- `:<velociraptor-version>-<revision>` — e.g. `:0.77.3-5`. Never changes once published.
- `:<minor>` — e.g. `:0.77`. The newest patch of that minor line.
- `:sha-<short>` — the commit the image was built from.
- Multi-arch manifests are published for **amd64** and **arm64**

---

## Build & Release Flow

- **`upstream-check.yml`** (daily) polls the Velocidex releases and the official Triage and Sigma artifact projects:
  - The image version is the version of the two Linux server binaries. If they differ, or a new release is under 48 hours old and still missing assets, it waits.
  - It refuses to "bump" to an older version, ignores artifact rebuilds that only change an embedded build stamp, and keeps a single bump PR (`upstream-check/bump`) up to date.
  - **Server config changes:** every version bump runs `scripts/config-drift.sh` on the old and new server binaries. It compares the config each release generates, and checks that the new release still loads a config made by the old one (keys, nonces and build stamps are masked). The report goes into the PR description and is committed as `docs/config-drift/<version>.md`. The PR is labeled `config-changes` when settings were added or removed or defaults changed, and `config-incompatible` when the old config no longer loads. Existing installs keep their persisted config, so these are the changes to review for reconcile mode or upgrade notes. Run the same check on demand with the **config-drift** workflow, or locally (see the script header).
  - Each bump is validated by a `build-publish` dry run on that branch (PRs opened with `GITHUB_TOKEN` get no PR checks). Failures open an issue, and the workflow keeps its own schedule from being disabled.
- **`build-publish.yml`** first lints (shell syntax, shellcheck, Python syntax, actionlint), then builds natively on amd64 and arm64 runners and runs the full validation on both:
  - `scripts/ci-image-validation.sh`: unprivileged server, private config, healthcheck, GUI and GUI API login, all 12 bundled artifacts and an extra one loaded by the running server, all 11 client bundles, `.deb`/`.rpm` installs, a repacked client enrolling and completing a collection, and the musl client on Alpine.
  - `scripts/ci-config-modes-validation.sh`: config modes, secrets, invalid input, interrupted first start, reverse-proxy URLs, the artifact manifest (install, include filter, override, disable, removal, offline cache, strict/lenient), and real upgrades from published `0.76.5`, `0.77.2` and `0.77.3-4` images in which an enrolled client keeps its identity.
  - A separate job runs `ci-image-validation.sh` under rootless Podman.
  - Publishing (a `v*` tag, or a manual run with `dry_run` unchecked on `main` or a tag) pushes each architecture by digest, validates that pushed image, and only then creates the multi-arch tags.
- **`release-tag.yml`** runs when `versions.env` changes on `main`: it tags the merge commit (`v<version>`, or `v<version>-<revision>` for revisions after the first) and starts the release build. Merging a bump PR, or a PR that raises `IMAGE_REVISION`, is all it takes to publish.
- Dependabot keeps the SHA-pinned actions and the digest-pinned base image current.

Required repository secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`.

To test the whole release path without releasing (for example after updating the workflow actions), run **release-tag** with `rehearsal` checked, or `gh workflow run release-tag.yml -f rehearsal=true`. It pushes and deletes a throwaway git tag, then runs build-publish end to end: the Docker Hub login, both architectures pushed by digest and validated, the digest hand-off and the multi-arch merge. The only tag it writes is `:rehearsal`, which users don't pull.

Build locally from the pinned lockfiles:

```bash
scripts/build.sh velociraptor:local
IMAGE=velociraptor:local scripts/ci-image-validation.sh
```

---

### About This Fork

This repository is a fork of [weslambert/velociraptor-docker](https://github.com/weslambert/velociraptor-docker), originally created by **Wes Lambert**.  
It aims to maintain compatibility with the latest [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor) releases while providing additional configuration options and deployment improvements for Docker environments.

All credit for the foundational work goes to Wes Lambert — this fork primarily adds quality-of-life enhancements, updated configurations, and maintenance updates.

---

**Maintained by:** [Xboarder56](https://github.com/Xboarder56)  
**Upstream project:** [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor)
