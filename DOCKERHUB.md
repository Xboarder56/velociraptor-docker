# Velociraptor server in Docker

The [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor) DFIR server, ready to run: HTTPS, prebuilt client installers, and bundled Triage, Sigma and Hayabusa artifacts. amd64 + arm64.

**Full documentation:** [github.com/Xboarder56/velociraptor-docker](https://github.com/Xboarder56/velociraptor-docker#readme)

## Quick start

```bash
docker run -d --name velociraptor \
  -p 8000:8000 -p 8889:8889 \
  -v velodata:/velociraptor \
  -e VELOX_FRONTEND_HOSTNAME=velociraptor.example.com \
  -e VELOX_DEFAULT_PASSWORD='change-me' \
  docker.io/xboarder56/velociraptor:latest
```

Open `https://<host>:8889` and log in as `admin`. Clients connect to port `8000`.

## What you get

- Repacked clients for Linux (amd64, arm64, static musl), macOS and Windows, plus `.deb`/`.rpm`/`.msi`, in `/velociraptor/client_bundles/` and as GUI downloads
- `Windows.Triage.Targets`, `Linux.Triage.UAC`, Hayabusa and Sigma triage artifacts, pinned and verified
- Your own artifacts: drop `*.yaml` into `/velociraptor/artifacts/`, or declare URLs + SHA-256 in `/velociraptor/artifacts.yaml`
- Runs as an unprivileged user; config with private keys is `0600`
- Binaries verified against pinned SHA-256 and the Velocidex release signature
- Automatic certificate rotation, healthcheck, Docker and rootless Podman

## Key settings

| Variable | Purpose |
| --- | --- |
| `VELOX_FRONTEND_HOSTNAME` | Address clients connect to |
| `VELOX_DEFAULT_PASSWORD` / `_FILE` | Bootstrap admin password |
| `VELOX_FRONTEND_SERVER_URL` / `VELOX_GUI_URL` | Public URLs (reverse proxy) |
| `VELOX_CONFIG_MODE` | `reconcile` (default), `generated` or `external` |
| `VELOX_UID` / `VELOX_GID` | Server account (default `10001`) |

All settings, compose example, upgrade notes: see the [README](https://github.com/Xboarder56/velociraptor-docker#readme).

## Tags

- `latest`: newest release
- `<version>`, e.g. `0.77.4`: follows image revisions of that Velociraptor release
- `<version>-<revision>`, e.g. `0.77.4-2`: fixed, never changes
- `<minor>`, e.g. `0.77`: newest patch of that minor line

Published automatically from the [GitHub repository](https://github.com/Xboarder56/velociraptor-docker) after full CI validation.
