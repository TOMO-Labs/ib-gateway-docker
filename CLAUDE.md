# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides a Docker image to run Interactive Brokers Gateway (IB Gateway) in a container without human interaction. It's designed for automated trading applications.

**Key Components:**
- IB Gateway: Interactive Brokers trading platform
- IBC (Interactive Brokers Controller): Automates user interactions with IB Gateway
- Xvfb: Virtual framebuffer for running GUI applications headlessly
- x11vnc: Optional VNC server for remote GUI access
- HAProxy: TCP proxy for exposing API ports with health checks and monitoring

## Repository Structure

### Build System Architecture

The repository uses a **simplified single-Dockerfile build system**:

- **Dockerfile:** Single `Dockerfile` at the repository root
- **Config templates:** Configuration templates in `config/` directory
- **Scripts:** Runtime scripts in `scripts/` directory
- **Direct editing:** Edit the Dockerfile and supporting files directly - no code generation needed

**Key directories:**
```
config/              # Config templates
├── haproxy/        # HAProxy config templates (haproxy.cfg.tmpl)
├── ibgateway/      # IB Gateway config templates (jts.ini.tmpl)
└── ibc/            # IBC config templates (config.ini.tmpl)

scripts/             # Runtime scripts (run.sh, common.sh, run_haproxy.sh)

Dockerfile           # Single Dockerfile for ib-gateway
docker-compose.yml   # Docker compose for ib-gateway
```

### Container Image

The **ib-gateway** container image (from `Dockerfile`): Headless IB Gateway with optional VNC access
- Base user: `ibgateway` (UID 1000)
- Home: `/home/ibgateway`
- API ports: 4001 (live), 4002 (paper) - proxied through HAProxy with health checks
- HAProxy stats: 8404 (monitoring web UI at /stats)
- VNC port: 5900 (optional)

## Development Workflow

### Building Images

Edit the `Dockerfile` and supporting files in `config/` and `scripts/` directories directly:

1. Edit `Dockerfile`, or files in `config/` or `scripts/` as needed
2. Build: `docker compose up --build`

### Testing

**Local testing:**
```bash
docker compose up --build
```

**Access VNC:**
- Connect to `localhost:5900` with VNC client
- Password set via `VNC_SERVER_PASSWORD` environment variable

### Version Updates

When updating to a new IB Gateway version:

1. Update version in `Dockerfile` and workflow files (`.github/workflows/`)
2. Test builds locally: `docker compose up --build`
3. The GitHub workflow will build multi-arch images (amd64/arm64)

## Configuration System

### Environment Variable Processing

The container uses a **template-based configuration system**:

1. **Templates:** Config files have `.tmpl` extension (e.g., `jts.ini.tmpl`, `config.ini.tmpl`)
2. **Runtime substitution:** The `run.sh` script uses `envsubst` to replace `${VARIABLE}` placeholders with environment variable values
3. **Generated configs:** Templates are processed into actual config files at container startup
4. **Custom configs:** Set `CUSTOM_CONFIG=yes` to skip template processing and provide your own config files via volumes

### Important File Locations

**IB Gateway container:**
- IB Gateway settings: `${TWS_SETTINGS_PATH}` (default: `/home/ibgateway/Jts`)
- IBC config: `/home/ibgateway/ibc/config.ini`
- JTS config: `/home/ibgateway/Jts/jts.ini`

### Trading Modes

The container supports three `TRADING_MODE` values:
- `paper`: Paper trading only (default)
- `live`: Live trading only
- `both`: Runs both live and paper instances in parallel within the same container

When `TRADING_MODE=both`:
- Separate credentials required: `TWS_USERID_PAPER` and `TWS_PASSWORD_PAPER`
- Settings paths are prefixed: `${TWS_SETTINGS_PATH}_live` and `${TWS_SETTINGS_PATH}_paper`
- Different API ports used for live vs paper

### Key Environment Variables

**Authentication & Session Management:**
- `TWS_USERID`, `TWS_PASSWORD`: IB credentials (or use `_FILE` variants for Docker secrets)
- `TWOFA_TIMEOUT_ACTION`: Action on 2FA timeout (`exit` or `restart`)
- `TWOFA_EXIT_INTERVAL`: Seconds to wait before exiting after 2FA timeout (default: 60)
- `RELOGIN_AFTER_TWOFA_TIMEOUT`: Auto-retry login after 2FA timeout (`yes` or `no`)
- `AUTO_RESTART_TIME`: Daily restart time (format: `HH:MM AM/PM`) - avoids daily 2FA after first login
- `TWS_COLD_RESTART`: Complete Java restart time (format: `HH:MM` 24-hour)

**API Settings:**
- `TWS_ACCEPT_INCOMING`: Accept API connections (`accept`, `reject`, `manual` - default: `manual`)
- `READ_ONLY_API`: Prevent API from placing orders (`yes` or `no`)
- `TWS_MASTER_CLIENT_ID`: Restrict to specific client ID

**Advanced:**
- `CUSTOM_CONFIG`: Skip template processing, use custom config files (`yes` or `NO`)
- `JAVA_HEAP_SIZE`: Java heap in MB (default: 768)
- `HAPROXY_RESTART`: Seconds to wait before restarting HAProxy if it exits (default: 5)

## Port Forwarding Architecture

**Why HAProxy is needed:**
IB Gateway binds API ports to `127.0.0.1` (localhost only) inside the container for security. To make these ports accessible to other containers or the host, HAProxy proxies connections with additional features:

**Architecture:**
```
IB Gateway (localhost) → HAProxy (TCP proxy) → Docker port mapping → Host
127.0.0.1:4001        → 0.0.0.0:4001      → 127.0.0.1:4001
127.0.0.1:4002        → 0.0.0.0:4002      → 127.0.0.1:4002
```

**HAProxy Features:**
- **Health Checks:** Probes IB Gateway every 2 seconds, marks backends down after 2 failures
- **Connection Limits:** Max 200 concurrent connections per port (live/paper)
- **Long Timeouts:** 6-hour client/server timeouts for persistent IB connections
- **Stats Page:** Web UI at `http://localhost:8404/stats` showing connection metrics and health status
- **Graceful Reload:** Can reload configuration without dropping connections
- **Better Logging:** Structured TCP logs with timestamps, durations, byte counts to Docker logs

**HAProxy Configuration:**
- Template: `config/haproxy/haproxy.cfg.tmpl`
- Generated at runtime: `${HOME}/haproxy/haproxy.cfg`
- Startup script: `scripts/run_haproxy.sh`

## Start-up Scripts

The container supports three stages of custom start-up scripts:

1. **START_SCRIPTS** (`$HOME/START_SCRIPTS`): Runs before X environment starts
2. **X_SCRIPTS** (`$HOME/X_SCRIPTS`): Runs after X environment is up
3. **IBC_SCRIPTS** (`$HOME/IBC_SCRIPTS`): Runs after IBC starts

Scripts must:
- Have `.sh` extension
- Be executable
- Be mounted via volume (e.g., `${PWD}/init-scripts:/home/ibgateway/init-scripts`)
- Run in alphabetical order (e.g., `00-first.sh` runs before `99-last.sh`)

For ib-gateway, `$HOME=/home/ibgateway`.

## Security Considerations

**Critical security notes:**
- IB API uses unencrypted, unauthenticated TCP sockets
- Default docker-compose exposes ports only to `127.0.0.1` on host
- Never expose API ports to untrusted networks without additional security (VPN, SSH port forwarding, etc.)
- Credential files (`_FILE` variables) support Docker secrets for production deployments

## CI/CD

GitHub Actions workflows:
- `build.yml`: Builds ib-gateway image for amd64 and arm64
- `publish.yml`: Publishes images to GitHub Container Registry and Docker Hub
- `detect-releases.yml`: Automatically detects new IB Gateway releases
- `detect-ibc-release.yml`: Automatically detects new IBC releases

Multi-arch support uses QEMU for arm64 builds on amd64 runners.

## Common Tasks

**Update IB Gateway version:**
1. Update the `IB_GATEWAY_VERSION` in the `Dockerfile`
2. Update version in workflow files (`.github/workflows/`)
3. Test the build locally: `docker compose build`

**Build image:**
```bash
docker compose build
```

**Restart HAProxy in running container:**
```bash
# Restart HAProxy
docker exec -it algo-trader-ib-gateway-1 pkill -x haproxy
```

**Access HAProxy stats:**
Open http://localhost:8404/stats in your browser to view:
- Connection counts and rates
- Backend health status
- Request/response bytes
- Connection durations

**Preserve settings across container restarts:**
Set `TWS_SETTINGS_PATH` and mount it as a volume in docker-compose.yml.

## Common Issues

### Issue 1: "can't find jars folder" Error

**Symptom:**
```
Error: Offline TWS/Gateway version 10.41.1d is not installed: can't find jars folder
Make sure you install the offline version of TWS/Gateway
IBC does not work with the auto-updating TWS/Gateway
```

**Root Cause:**
Volume mount at `/home/ibgateway/Jts` overwrites the IB Gateway installation directory, hiding the installed jars.

**Problem Configuration:**
```yaml
# ❌ WRONG - This hides the IB Gateway installation
volumes:
  - ib-gateway-settings:/home/ibgateway/Jts
```

When you mount a volume at `/home/ibgateway/Jts`, Docker **replaces** the entire directory with the volume contents, which hides:
- `/home/ibgateway/Jts/ibgateway/10.41.1d/` (the installed IB Gateway)
- `/home/ibgateway/Jts/ibgateway/10.41.1d/jars/` (the jar files IBC needs)

**Solution:**
Use `TWS_SETTINGS_PATH` to point to a separate directory for persistent settings:

```yaml
# ✅ CORRECT - Settings in separate directory
services:
  ib-gateway:
    image: ghcr.io/tomo-labs/ib-gateway:latest
    environment:
      TWS_SETTINGS_PATH: /home/ibgateway/settings  # Point to separate directory
    volumes:
      - ib-gateway-settings:/home/ibgateway/settings  # Mount volume at settings path
```

This way:
- IB Gateway installation remains at: `/home/ibgateway/Jts/ibgateway/10.41.1d/jars/` ✅
- Settings persist at: `/home/ibgateway/settings/` ✅
- No conflict between installation and settings ✅

**Alternative Solutions:**

1. **No volume (settings don't persist):**
```yaml
services:
  ib-gateway:
    image: ghcr.io/tomo-labs/ib-gateway:latest
    # No volume mount - settings reset on each restart
```

2. **Mount specific files only:**
```yaml
services:
  ib-gateway:
    image: ghcr.io/tomo-labs/ib-gateway:latest
    volumes:
      # Mount individual config files, not entire directory
      - ./jts.ini:/home/ibgateway/Jts/jts.ini
      - ./config.ini:/home/ibgateway/ibc/config.ini
```

### Issue 2: Docker Build Cache Issues

**Symptom:**
After fixing the Dockerfile, new images still fail with the same errors.

**Root Cause:**
Docker layer caching reuses old broken layers even after fixing the Dockerfile.

**Solution:**
The Dockerfile includes a `CACHE_BUST` build argument to force fresh builds when needed. This is already set up in the Dockerfile:

```dockerfile
ARG CACHE_BUST=1
RUN echo "Cache bust: v${CACHE_BUST}" && \
  apt-get update -y && \
  ...
```

If you need to force a completely fresh build locally:
```bash
docker compose build --no-cache
```

### Issue 3: Published Images Not Updating

**Symptom:**
GitHub Actions workflows run successfully, but pulling images still gives old/broken versions.

**Root Cause:**
The `publish.yml` workflow only triggers on tags matching `v*` pattern.

**Solution:**
Create and push a new version tag to trigger image publishing:
```bash
git tag v10.41.1d.X  # Replace X with next increment
git push origin v10.41.1d.X
```

This triggers the publish workflow which:
1. Builds fresh images for amd64 and arm64
2. Pushes to GitHub Container Registry (ghcr.io/tomo-labs/ib-gateway)
3. Pushes to Docker Hub (lohanjacobs/ib-gateway-ibc-runner)
