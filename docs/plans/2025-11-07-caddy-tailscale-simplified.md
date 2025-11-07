# Caddy + Tailscale Migration Implementation Plan (Simplified Repository)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace socat with Caddy reverse proxy and add Tailscale network isolation for IB Gateway Docker container.

**Architecture:** Install Caddy + Tailscale in container, bind Caddy to Tailscale IP only, remove socat and SSH tunnel code. Security via WireGuard encryption, monitoring via Caddy logs and health endpoints. Single Dockerfile build (no templates).

**Tech Stack:** Caddy (reverse proxy), Tailscale (WireGuard VPN), Docker, Bash scripting, envsubst (template processing)

---

## Task 1: Create Caddy Configuration Template

**Files:**
- Create: `config/caddy/Caddyfile.tmpl`

**Step 1: Create directory structure**

```bash
mkdir -p config/caddy
```

**Step 2: Write Caddyfile template**

Create `config/caddy/Caddyfile.tmpl` with this content:

```caddyfile
{
    admin off
    log {
        level ${CADDY_LOG_LEVEL}
    }
}

# Health check endpoint (localhost only)
:2019 {
    respond /health 200
    respond /ready 200
    respond /metrics 200
}

# IB API TCP proxy - binds to Tailscale IP only
${TAILSCALE_IP}:${PUBLISHED_PORT} {
    reverse_proxy 127.0.0.1:${LOCAL_PORT} {
        transport tcp
    }

    log {
        output file /var/log/caddy/access-${TRADING_MODE}.log
    }
}
```

**Step 3: Verify template syntax**

Check that the file contains the required placeholders:
- `${CADDY_LOG_LEVEL}`
- `${TAILSCALE_IP}`
- `${PUBLISHED_PORT}`
- `${LOCAL_PORT}`
- `${TRADING_MODE}`

**Step 4: Commit**

```bash
git add config/caddy/Caddyfile.tmpl
git commit -m "feat: add Caddy configuration template"
```

---

## Task 2: Update Dockerfile - Remove socat and SSH

**Files:**
- Modify: `Dockerfile` (line 93)

**Step 1: Remove socat and SSH packages**

Find this line (line 93):
```dockerfile
apt-get install --no-install-recommends --yes \
  gettext-base socat xvfb x11vnc sshpass openssh-client sudo telnet && \
```

Replace with:
```dockerfile
apt-get install --no-install-recommends --yes \
  gettext-base xvfb x11vnc sudo telnet curl gnupg && \
```

**Step 2: Verify change**

Read `Dockerfile` line 93 to confirm `socat`, `sshpass`, and `openssh-client` are removed and `curl gnupg` are added.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "refactor: remove socat and SSH packages from Dockerfile"
```

---

## Task 3: Update Dockerfile - Install Caddy

**Files:**
- Modify: `Dockerfile` (after line 95)

**Step 1: Add Caddy installation**

After the `apt-get clean` block (around line 95), add these lines:

```dockerfile
# Install Caddy
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
    gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
    tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install --no-install-recommends --yes caddy && \
```

Insert this BEFORE the line that starts with `if id ubuntu;`.

**Step 2: Verify change**

Read the updated section to confirm Caddy installation is added.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Caddy installation to Dockerfile"
```

---

## Task 4: Update Dockerfile - Install Tailscale

**Files:**
- Modify: `Dockerfile` (after Caddy installation)

**Step 1: Add Tailscale installation**

After the Caddy installation block, add:

```dockerfile
# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh && \
```

**Step 2: Verify change**

Read the updated section to confirm Tailscale installation is added.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Tailscale installation to Dockerfile"
```

---

## Task 5: Update Dockerfile - Create Caddy Log Directory

**Files:**
- Modify: `Dockerfile` (after Tailscale installation)

**Step 1: Create Caddy log directory**

After the Tailscale installation, add:

```dockerfile
# Create Caddy log directory
RUN mkdir -p /var/log/caddy && \
    chown ${USER_ID}:${USER_GID} /var/log/caddy && \
```

**Step 2: Verify change**

Read the updated section to confirm log directory creation is added.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: create Caddy log directory in Dockerfile"
```

---

## Task 6: Update Dockerfile - Copy Caddy Config Template

**Files:**
- Modify: `Dockerfile` (around line 57, in setup stage)

**Step 1: Add Caddy config copy**

Find the section in the setup stage where config files are copied (around line 57-58):

```dockerfile
COPY ./config/ibgateway/jts.ini.tmpl /root/Jts/jts.ini.tmpl
COPY ./config/ibc/config.ini.tmpl /root/ibc/config.ini.tmpl
```

Add after these lines:

```dockerfile
COPY ./config/caddy /root/caddy-config
```

**Step 2: Verify change**

Read the updated section to confirm Caddy config is copied.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: copy Caddy config template in Dockerfile"
```

---

## Task 7: Add Tailscale Startup Function to common.sh

**Files:**
- Modify: `scripts/common.sh` (after line 123, before port_forwarding)

**Step 1: Add start_tailscale function**

Add this function after `set_java_heap()` function (around line 123):

```bash
start_tailscale() {
    echo ".> Starting Tailscale daemon..."

    # Create state directory if it doesn't exist
    mkdir -p /var/lib/tailscale

    # Start tailscaled in background with userspace networking
    tailscaled --tun=userspace-networking --state=/var/lib/tailscale/state.conf &
    sleep 2

    # Bring up Tailscale network
    echo ".> Connecting to Tailscale network..."
    local hostname="${TAILSCALE_HOSTNAME:-$(hostname)}"

    if [ -z "$TAILSCALE_AUTHKEY" ]; then
        echo ".> ERROR: TAILSCALE_AUTHKEY environment variable is required"
        exit 1
    fi

    tailscale up --authkey="${TAILSCALE_AUTHKEY}" \
                 --hostname="${hostname}" \
                 ${TAILSCALE_EXTRA_ARGS}

    # Wait for Tailscale IP
    echo ".> Waiting for Tailscale IP..."
    local max_attempts=30
    local attempt=0

    while [ -z "$TAILSCALE_IP" ] && [ $attempt -lt $max_attempts ]; do
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)
        if [ -z "$TAILSCALE_IP" ]; then
            sleep 1
            attempt=$((attempt + 1))
        fi
    done

    if [ -z "$TAILSCALE_IP" ]; then
        echo ".> ERROR: Failed to obtain Tailscale IP after ${max_attempts} seconds"
        exit 1
    fi

    export TAILSCALE_IP
    echo ".> Tailscale connected with IP: ${TAILSCALE_IP}"
}
```

**Step 2: Verify syntax**

Check that the function is properly formatted and has no syntax errors.

**Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: add Tailscale startup function to common.sh"
```

---

## Task 8: Add Caddy Startup Function to common.sh

**Files:**
- Modify: `scripts/common.sh` (after start_tailscale function)

**Step 1: Add start_caddy function**

Add this function after `start_tailscale()`:

```bash
start_caddy() {
    echo ".> Starting Caddy reverse proxy..."

    if [ -z "$TAILSCALE_IP" ]; then
        echo ".> ERROR: TAILSCALE_IP not set. Run start_tailscale first."
        exit 1
    fi

    # Config template path
    local config_template="${HOME}/caddy-config/Caddyfile.tmpl"
    local config_output="/etc/caddy/Caddyfile"

    # Set default log level if not specified
    export CADDY_LOG_LEVEL="${CADDY_LOG_LEVEL:-INFO}"

    # Generate Caddyfile from template
    if [ -f "$config_template" ]; then
        sudo envsubst < "$config_template" | sudo tee "$config_output" > /dev/null
        echo ".> Generated Caddy config at ${config_output}"
    else
        echo ".> ERROR: Caddy config template not found at ${config_template}"
        exit 1
    fi

    # Start Caddy in background
    sudo caddy run --config "$config_output" &
    sleep 1

    echo ".> Caddy started successfully"
}
```

**Step 2: Verify syntax**

Check that the function is properly formatted.

**Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: add Caddy startup function to common.sh"
```

---

## Task 9: Replace port_forwarding Function in common.sh

**Files:**
- Modify: `scripts/common.sh` (lines 125-146)

**Step 1: Replace port_forwarding function**

Find the `port_forwarding()` function (lines 125-146). Replace the entire function with:

```bash
port_forwarding() {
    echo ".> Setting up port forwarding with Caddy..."

    # Start Tailscale first
    start_tailscale

    # Export port variables for Caddy config
    export PUBLISHED_PORT="${SOCAT_PORT}"
    export LOCAL_PORT="${API_PORT}"

    # Start Caddy
    start_caddy

    echo ".> Port forwarding setup complete"
    echo ".>   Local API: 127.0.0.1:${LOCAL_PORT}"
    echo ".>   Published: ${TAILSCALE_IP}:${PUBLISHED_PORT}"
}
```

**Step 2: Verify change**

Read the `port_forwarding` function to confirm it's been updated.

**Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "refactor: replace port_forwarding to use Caddy/Tailscale"
```

---

## Task 10: Remove setup_ssh Function from common.sh

**Files:**
- Modify: `scripts/common.sh` (lines 148-194)

**Step 1: Delete setup_ssh function**

Find and delete the entire `setup_ssh()` function (lines 148-194).

**Step 2: Verify deletion**

Confirm the function is removed and no references remain.

**Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "refactor: remove setup_ssh function"
```

---

## Task 11: Remove start_ssh Function from common.sh

**Files:**
- Modify: `scripts/common.sh` (lines 196-226)

**Step 1: Delete start_ssh function**

Find and delete the entire `start_ssh()` function (lines 196-226).

**Step 2: Verify deletion**

Confirm the function is removed.

**Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "refactor: remove start_ssh function"
```

---

## Task 12: Remove start_socat Function from common.sh

**Files:**
- Modify: `scripts/common.sh` (lines 228-243)

**Step 1: Delete start_socat function**

Find and delete the entire `start_socat()` function (lines 228-243).

**Step 2: Verify deletion**

Confirm the function is removed.

**Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "refactor: remove start_socat function"
```

---

## Task 13: Update stop_ibc Function in run.sh

**Files:**
- Modify: `scripts/run.sh` (lines 14-45)

**Step 1: Replace stop_ibc function**

Find the `stop_ibc()` function (lines 14-45). Replace it with:

```bash
stop_ibc() {
    echo ".> 😘 Received SIGINT or SIGTERM. Shutting down IB Gateway."

    # Stop Caddy
    if pgrep caddy >/dev/null; then
        echo ".> Stopping Caddy."
        sudo pkill caddy
    fi

    # Stop Tailscale
    if pgrep tailscaled >/dev/null; then
        echo ".> Stopping Tailscale."
        sudo pkill tailscaled
    fi

    # Stop VNC
    if pgrep x11vnc >/dev/null; then
        echo ".> Stopping x11vnc."
        pkill x11vnc
    fi

    # Stop Xvfb
    echo ".> Stopping Xvfb."
    pkill Xvfb

    # Stop IBC
    echo ".> Stopping IBC."
    kill -SIGTERM "${pid[@]}"

    # Wait for exit
    wait "${pid[@]}"

    # All done
    echo ".> Done... $?"
}
```

**Step 2: Verify change**

Read the updated function to confirm changes.

**Step 3: Commit**

```bash
git add scripts/run.sh
git commit -m "refactor: update stop_ibc for Caddy/Tailscale"
```

---

## Task 14: Remove setup_ssh Call from run.sh

**Files:**
- Modify: `scripts/run.sh` (line 113)

**Step 1: Remove setup_ssh call**

Find line 113 that calls `setup_ssh`. Delete these lines:

```bash
# setup SSH Tunnel
setup_ssh
```

**Step 2: Verify deletion**

Confirm the setup_ssh call is removed.

**Step 3: Commit**

```bash
git add scripts/run.sh
git commit -m "refactor: remove setup_ssh call from run.sh"
```

---

## Task 15: Delete Obsolete Scripts

**Files:**
- Delete: `scripts/run_socat.sh`
- Delete: `scripts/run_ssh.sh`

**Step 1: Delete run_socat.sh**

```bash
rm scripts/run_socat.sh
```

**Step 2: Delete run_ssh.sh**

```bash
rm scripts/run_ssh.sh
```

**Step 3: Verify deletion**

```bash
ls scripts/
```

Expected: Only `common.sh` and `run.sh` remain.

**Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove obsolete socat and SSH tunnel scripts"
```

---

## Task 16: Update docker-compose.yml - Add Tailscale Environment Variables

**Files:**
- Modify: `docker-compose.yml` (lines 10-47)

**Step 1: Add Tailscale environment variables**

Add these lines after line 10 (before `TWS_USERID`):

```yaml
      # Tailscale configuration
      TAILSCALE_AUTHKEY: ${TAILSCALE_AUTHKEY}
      TAILSCALE_HOSTNAME: ${TAILSCALE_HOSTNAME:-ib-gateway}
      TAILSCALE_TAGS: ${TAILSCALE_TAGS:-}
      TAILSCALE_EXTRA_ARGS: ${TAILSCALE_EXTRA_ARGS:-}
      # Caddy configuration
      CADDY_LOG_LEVEL: ${CADDY_LOG_LEVEL:-INFO}
```

**Step 2: Verify change**

Read the environment section to confirm Tailscale/Caddy variables are added.

**Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Tailscale/Caddy environment variables"
```

---

## Task 17: Update docker-compose.yml - Remove SSH Environment Variables

**Files:**
- Modify: `docker-compose.yml` (lines 36-44)

**Step 1: Remove SSH environment variables**

Delete these lines (36-44):

```yaml
      SSH_TUNNEL: ${SSH_TUNNEL:-}
      SSH_OPTIONS: ${SSH_OPTIONS:-}
      SSH_ALIVE_INTERVAL: ${SSH_ALIVE_INTERVAL:-}
      SSH_ALIVE_COUNT: ${SSH_ALIVE_COUNT:-}
      SSH_PASSPHRASE: ${SSH_PASSPHRASE:-}
      SSH_REMOTE_PORT: ${SSH_REMOTE_PORT:-}
      SSH_USER_TUNNEL: ${SSH_USER_TUNNEL:-}
      SSH_RESTART: ${SSH_RESTART:-}
      SSH_VNC_PORT: ${SSH_VNC_PORT:-}
```

**Step 2: Verify deletion**

Confirm all SSH_* variables are removed.

**Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "refactor: remove SSH environment variables"
```

---

## Task 18: Update docker-compose.yml - Add Volume Mounts

**Files:**
- Modify: `docker-compose.yml` (after line 52)

**Step 1: Uncomment and update volumes section**

Replace the commented volumes section (lines 48-53) with:

```yaml
    volumes:
      - tailscale-state:/var/lib/tailscale
      - caddy-logs:/var/log/caddy
      # Optional custom config volumes:
      # - ${PWD}/jts.ini:/home/ibgateway/Jts/jts.ini
      # - ${PWD}/config.ini:/home/ibgateway/ibc/config.ini
      # - ${PWD}/tws_settings/:${TWS_SETTINGS_PATH:-/home/ibgateway/Jts}
      # - ${PWD}/ssh/:/home/ibgateway/.ssh
      # - ${PWD}/scripts:/home/ibgateway/init-scripts
```

**Step 2: Add volume definitions**

Add at the end of the file (after line 57):

```yaml

volumes:
  tailscale-state:
  caddy-logs:
```

**Step 3: Verify change**

Read the volumes section to confirm changes.

**Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Tailscale and Caddy volume mounts"
```

---

## Task 19: Update docker-compose.yml - Update Port Comments

**Files:**
- Modify: `docker-compose.yml` (before line 54)

**Step 1: Update port mapping comments**

Add a comment before the `ports:` section:

```yaml
    # Port mappings: For backward compatibility. Primary access via Tailscale network.
    # Connect to API via Tailscale: <tailscale-hostname>.ts.net:4003 or <tailscale-ip>:4003
    ports:
```

**Step 2: Verify change**

Read the ports section to confirm comment is added.

**Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "docs: update port mapping comments for Tailscale"
```

---

## Task 20: Create Example .env File

**Files:**
- Create: `.env.example`

**Step 1: Create example environment file**

Create `.env.example` with:

```bash
# Tailscale Configuration (REQUIRED)
TAILSCALE_AUTHKEY=tskey-auth-your-key-here
TAILSCALE_HOSTNAME=ib-gateway
TAILSCALE_TAGS=tag:trading
TAILSCALE_EXTRA_ARGS=

# Caddy Configuration
CADDY_LOG_LEVEL=INFO

# IB Gateway Configuration
TRADING_MODE=paper
TWS_USERID=your_username
TWS_PASSWORD=your_password
VNC_SERVER_PASSWORD=vnc_password

# For dual mode (TRADING_MODE=both)
# TWS_USERID_PAPER=paper_username
# TWS_PASSWORD_PAPER=paper_password

# Optional settings
TIME_ZONE=America/New_York
TWS_SETTINGS_PATH=/home/ibgateway/Jts
```

**Step 2: Commit**

```bash
git add .env.example
git commit -m "docs: add example environment file with Tailscale config"
```

---

## Task 21: Update README.md - Remove SSH and socat References

**Files:**
- Modify: `README.md`

**Step 1: Search for SSH references**

```bash
grep -n "SSH\|ssh\|socat" README.md
```

**Step 2: Remove SSH tunnel sections**

Remove or update sections that mention:
- SSH tunnels
- SSH_TUNNEL environment variable
- socat port forwarding
- SSH configuration examples

Common sections to update:
- Environment variables table
- Configuration examples
- Security section
- Port forwarding explanations

**Step 3: Verify changes**

```bash
grep -n "SSH\|ssh\|socat" README.md
```

Expected: No references to SSH tunnels or socat remain (except in historical context if needed).

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: remove SSH tunnel and socat references from README"
```

---

## Task 22: Update README.md - Add Tailscale Setup Section

**Files:**
- Modify: `README.md`

**Step 1: Add Tailscale setup section**

Add a new section after "Quick Start" or "Configuration":

```markdown
## Tailscale Setup

This container requires Tailscale for secure network access to the IB Gateway API.

### Prerequisites

1. **Create a Tailscale account** at https://login.tailscale.com/
2. **Generate an auth key:**
   - Go to **Settings > Keys** in the Tailscale admin console
   - Create a new auth key
   - Enable **Reusable** and **Ephemeral** (recommended for containers)
   - Copy the key (starts with `tskey-auth-`)

### Configuration

Set the following environment variables in your `.env` file:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TAILSCALE_AUTHKEY` | **Yes** | - | Tailscale authentication key |
| `TAILSCALE_HOSTNAME` | No | `ib-gateway` | Custom hostname for your tailnet |
| `TAILSCALE_TAGS` | No | - | Tailscale ACL tags (e.g., `tag:trading`) |
| `TAILSCALE_EXTRA_ARGS` | No | - | Additional arguments for `tailscale up` |
| `CADDY_LOG_LEVEL` | No | `INFO` | Log level: DEBUG, INFO, WARN, ERROR |

### Connecting to the API

After the container starts, connect to the IB API using your Tailscale network:

**Using Tailscale hostname:**
```python
from ib_insync import IB
ib = IB()
ib.connect('ib-gateway', 4003, clientId=1)  # On same tailnet
# or with full domain:
ib.connect('ib-gateway.your-tailnet.ts.net', 4003, clientId=1)
```

**Using Tailscale IP:**
```bash
# Get the container's Tailscale IP
docker exec ib-gateway-1 tailscale ip -4
```

```python
ib.connect('100.64.x.x', 4003, clientId=1)  # Use IP from above
```

### Port Mappings

| Container Port | Purpose | Access Method |
|----------------|---------|---------------|
| 4003 | Live trading API | Via Tailscale network |
| 4004 | Paper trading API | Via Tailscale network |
| 5900 | VNC (optional) | localhost or Tailscale |
| 2019 | Health checks | Internal only |

**Note:** Ports 4001/4002 are still mapped to localhost for backward compatibility, but primary access should be via Tailscale.

### Security

- All traffic is encrypted via **WireGuard** (Tailscale's protocol)
- API is **only accessible** from devices on your Tailscale network
- No public internet exposure
- Use Tailscale ACLs for fine-grained access control
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add Tailscale setup and usage documentation"
```

---

## Task 23: Update README.md - Add Monitoring Section

**Files:**
- Modify: `README.md`

**Step 1: Add monitoring section**

Add a new "Monitoring" section:

```markdown
## Monitoring

### Health Checks

Caddy provides health check endpoints accessible from within the container:

```bash
# Check health
docker exec ib-gateway-1 curl http://localhost:2019/health

# Check readiness
docker exec ib-gateway-1 curl http://localhost:2019/ready
```

Integrate with Docker's HEALTHCHECK in your Dockerfile or docker-compose.yml:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:2019/health"]
  interval: 30s
  timeout: 3s
  start_period: 10s
  retries: 3
```

### Access Logs

Caddy logs all API connections to `/var/log/caddy/`:

```bash
# View live logs
docker exec ib-gateway-1 tail -f /var/log/caddy/access-live.log

# View paper trading logs (if TRADING_MODE=both)
docker exec ib-gateway-1 tail -f /var/log/caddy/access-paper.log
```

### Tailscale Status

Check Tailscale connectivity:

```bash
# View Tailscale status
docker exec ib-gateway-1 tailscale status

# Get Tailscale IP
docker exec ib-gateway-1 tailscale ip -4

# Network diagnostics
docker exec ib-gateway-1 tailscale netcheck
```
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add monitoring and health check documentation"
```

---

## Task 24: Update CLAUDE.md - Update Key Components

**Files:**
- Modify: `CLAUDE.md` (lines 8-15)

**Step 1: Update Key Components section**

Find the "Key Components" section and update:

```markdown
**Key Components:**
- IB Gateway: Interactive Brokers trading platform
- IBC (Interactive Brokers Controller): Automates user interactions with IB Gateway
- Xvfb: Virtual framebuffer for running GUI applications headlessly
- x11vnc: Optional VNC server for remote GUI access
- Caddy: Reverse proxy for API port forwarding with monitoring
- Tailscale: WireGuard VPN for secure network access
```

**Step 2: Verify change**

Read the section to confirm updates.

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update Key Components in CLAUDE.md"
```

---

## Task 25: Update CLAUDE.md - Update Port Forwarding Architecture

**Files:**
- Modify: `CLAUDE.md` (lines 53-64)

**Step 1: Replace Port Forwarding Architecture section**

Find and replace the "Port Forwarding Architecture" section:

```markdown
## Port Forwarding Architecture

**Why Caddy is needed:**
IB Gateway binds API ports to `127.0.0.1` (localhost only) inside the container for security. To make these ports accessible to other containers or the host, Caddy proxies connections:

- IB Gateway: `127.0.0.1:4001` → Caddy on `${TAILSCALE_IP}:4003`
- IB Gateway: `127.0.0.1:4002` → Caddy on `${TAILSCALE_IP}:4004`

Caddy binds **only to the Tailscale IP**, ensuring the API is accessible only from the Tailscale network.

**Tailscale Network Security:**
All traffic is encrypted via WireGuard. Only devices on your Tailscale network can access the IB API. The `docker-compose.yml` still maps ports to localhost for backward compatibility, but primary access should be via Tailscale.
```

**Step 2: Remove old SSH tunnel references**

Find and delete the "SSH Tunnel Alternative" section if it exists.

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update Port Forwarding Architecture in CLAUDE.md"
```

---

## Task 26: Update CLAUDE.md - Update Security Considerations

**Files:**
- Modify: `CLAUDE.md` (lines 66-73)

**Step 1: Update Security Considerations section**

Replace the security section:

```markdown
## Security Considerations

**Critical security notes:**
- IB API uses unencrypted, unauthenticated TCP sockets at the application layer
- Tailscale encrypts all traffic via WireGuard at the network layer
- API only accessible from devices on your Tailscale network
- Never expose API ports to untrusted networks
- Use Tailscale ACLs to further restrict access by device or user
- Credential files (`_FILE` variables) support Docker secrets for production deployments
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update Security Considerations in CLAUDE.md"
```

---

## Task 27: Create Migration Guide

**Files:**
- Create: `docs/MIGRATION_CADDY_TAILSCALE.md`

**Step 1: Create docs directory if needed**

```bash
mkdir -p docs
```

**Step 2: Create migration guide**

Create `docs/MIGRATION_CADDY_TAILSCALE.md` with comprehensive migration instructions. See full content in original plan Task 20, adapted for simplified repository structure.

Key sections:
- Breaking Changes
- Prerequisites (Tailscale account and auth key)
- Migration Steps (update docker-compose.yml, .env)
- Install Tailscale on client
- Update trading application connection
- Troubleshooting
- Rollback plan
- Benefits of new architecture

**Step 3: Commit**

```bash
git add docs/MIGRATION_CADDY_TAILSCALE.md
git commit -m "docs: add migration guide for Caddy/Tailscale"
```

---

## Task 28: Test Build - Build Container

**Files:**
- Tests: Build system

**Step 1: Ensure clean build environment**

```bash
docker compose down -v
docker system prune -f
```

**Step 2: Build the container**

```bash
docker compose build --no-cache
```

**Expected output:**
- Caddy installation succeeds
- Tailscale installation succeeds
- No errors about missing socat or SSH packages
- Build completes successfully

**Step 3: Verify build size**

```bash
docker images | grep ib-gateway
```

Note the image size (should be reasonable, not bloated).

**Step 4: Document results**

If build fails, document the error and fix before continuing. If successful, proceed to next task.

---

## Task 29: Test Runtime - Create Test .env File

**Files:**
- Create: `.env` (for testing only)

**Step 1: Create test .env file**

**IMPORTANT:** You must have a valid Tailscale auth key to proceed.

If you don't have one:
1. Visit https://login.tailscale.com/admin/settings/keys
2. Create a new auth key
3. Enable "Reusable" and "Ephemeral"
4. Copy the key

Create `.env`:

```bash
TAILSCALE_AUTHKEY=tskey-auth-YOUR-ACTUAL-KEY-HERE
TAILSCALE_HOSTNAME=ib-gateway-test
CADDY_LOG_LEVEL=DEBUG
TWS_USERID=fdemo
TWS_PASSWORD=demouser
TRADING_MODE=paper
VNC_SERVER_PASSWORD=test123
TIME_ZONE=America/New_York
```

**Step 2: Add .env to .gitignore**

Ensure `.env` is in `.gitignore` (it should already be):

```bash
grep "^\.env$" .gitignore || echo ".env" >> .gitignore
```

**Step 3: Do NOT commit**

The `.env` file should never be committed (it contains secrets).

---

## Task 30: Test Runtime - Start Container

**Files:**
- Tests: Container startup

**Step 1: Start the container**

```bash
docker compose up -d
```

**Step 2: Follow logs**

```bash
docker compose logs -f
```

**Expected log messages:**
- `.> Starting Tailscale daemon...`
- `.> Connecting to Tailscale network...`
- `.> Tailscale connected with IP: 100.x.x.x`
- `.> Starting Caddy reverse proxy...`
- `.> Generated Caddy config at /etc/caddy/Caddyfile`
- `.> Caddy started successfully`
- `.> Port forwarding setup complete`
- `.> Starting IBC in paper mode...`

**Step 3: Check for errors**

If errors occur:
- Tailscale auth key invalid → Get new key
- Tailscale IP timeout → Check network connectivity
- Caddy config error → Check template syntax
- Permission errors → Check file permissions

**Step 4: Document results**

Note any issues encountered and resolutions.

---

## Task 31: Test Runtime - Verify Tailscale

**Files:**
- Tests: Tailscale connectivity

**Step 1: Check Tailscale status**

```bash
docker exec algo-trader-ib-gateway-1 tailscale status
```

**Expected:** Shows device online with hostname and IP.

**Step 2: Get Tailscale IP**

```bash
docker exec algo-trader-ib-gateway-1 tailscale ip -4
```

**Expected:** Returns IP like `100.64.x.x`

**Step 3: Verify network connectivity**

```bash
docker exec algo-trader-ib-gateway-1 tailscale netcheck
```

**Expected:** Shows network diagnostics with successful DERP connections.

**Step 4: Document Tailscale IP**

Note the IP address for API connection testing.

---

## Task 32: Test Runtime - Verify Caddy Health Endpoints

**Files:**
- Tests: Caddy health checks

**Step 1: Test health endpoint**

```bash
docker exec algo-trader-ib-gateway-1 curl -v http://localhost:2019/health
```

**Expected:** Returns HTTP 200 with body "OK"

**Step 2: Test ready endpoint**

```bash
docker exec algo-trader-ib-gateway-1 curl -v http://localhost:2019/ready
```

**Expected:** Returns HTTP 200 with body "OK"

**Step 3: Test metrics endpoint**

```bash
docker exec algo-trader-ib-gateway-1 curl -v http://localhost:2019/metrics
```

**Expected:** Returns HTTP 200 with body "OK"

**Step 4: Document results**

Confirm all health endpoints are working.

---

## Task 33: Test Runtime - Verify Caddy Logs

**Files:**
- Tests: Caddy logging

**Step 1: Check if log file exists**

```bash
docker exec algo-trader-ib-gateway-1 ls -la /var/log/caddy/
```

**Expected:** Shows `access-paper.log` (or `access-live.log` if TRADING_MODE=live)

**Step 2: View log contents**

```bash
docker exec algo-trader-ib-gateway-1 cat /var/log/caddy/access-paper.log
```

**Expected:** May be empty initially (no connections yet) or show connection attempts.

**Step 3: Test log rotation**

Logs should be written to by Caddy. This will be verified when API connections are made.

---

## Task 34: Test Runtime - Verify Port Forwarding

**Files:**
- Tests: Caddy reverse proxy

**Step 1: Check Caddy config**

```bash
docker exec algo-trader-ib-gateway-1 cat /etc/caddy/Caddyfile
```

**Expected:** Config shows:
- Health endpoint on `:2019`
- Reverse proxy on `<TAILSCALE_IP>:4004` → `127.0.0.1:4002` (for paper mode)
- Log file path includes `/var/log/caddy/access-paper.log`

**Step 2: Check Caddy process**

```bash
docker exec algo-trader-ib-gateway-1 pgrep -a caddy
```

**Expected:** Shows Caddy running with config file.

**Step 3: Verify port bindings**

```bash
docker exec algo-trader-ib-gateway-1 netstat -tlnp 2>/dev/null | grep -E "2019|4003|4004"
```

**Expected:** Shows Caddy listening on:
- `127.0.0.1:2019` (health checks)
- `<TAILSCALE_IP>:4004` (paper API proxy)

Note: If `netstat` is not available, skip this step.

---

## Task 35: Test Runtime - Stop Container

**Files:**
- Tests: Graceful shutdown

**Step 1: Stop container**

```bash
docker compose down
```

**Step 2: Check shutdown logs**

```bash
docker compose logs --tail=50
```

**Expected log messages:**
- `.> 😘 Received SIGINT or SIGTERM. Shutting down IB Gateway.`
- `.> Stopping Caddy.`
- `.> Stopping Tailscale.`
- `.> Stopping Xvfb.`
- `.> Stopping IBC.`
- `.> Done... 0`

**Step 3: Verify clean shutdown**

Confirm no error messages during shutdown.

**Step 4: Clean up test environment**

```bash
docker compose down -v
```

This removes volumes (Tailscale state, Caddy logs).

---

## Task 36: Update GitHub Workflows (Optional)

**Files:**
- May need updates: `.github/workflows/*.yml`

**Step 1: Review workflow files**

```bash
ls -la .github/workflows/
```

**Step 2: Check if workflows need updates**

Review:
- `build.yml` - May need to build new image
- `publish.yml` - May need version tagging
- `detect-releases.yml` - Should work as-is

**Step 3: Update workflows if needed**

This task may be skipped if workflows are already compatible. Major changes:
- No template generation needed
- No dual-channel builds
- Single Dockerfile build

**Step 4: Commit workflow updates if made**

```bash
git add .github/workflows/
git commit -m "ci: update workflows for simplified build"
```

---

## Task 37: Final Verification and Summary

**Files:**
- Review: All changes

**Step 1: Review all commits**

```bash
git log --oneline --graph -30
```

**Expected commits:**
- Caddy config template
- Dockerfile updates (remove socat/SSH, install Caddy/Tailscale)
- Script updates (common.sh, run.sh)
- Deleted scripts (run_socat.sh, run_ssh.sh)
- docker-compose.yml updates
- .env.example creation
- README.md updates (remove SSH, add Tailscale, add monitoring)
- CLAUDE.md updates
- Migration guide

**Step 2: Verify no SSH/socat references remain**

```bash
git grep -i "socat\|ssh_tunnel" -- ':!docs/MIGRATION*' ':!docs/plans/*'
```

**Expected:** No results (except in excluded docs).

**Step 3: Create summary**

Document what was changed:
- Replaced socat with Caddy
- Replaced SSH tunnels with Tailscale
- Updated all documentation
- Created migration guide
- Tested build and runtime

**Step 4: Check for uncommitted changes**

```bash
git status
```

**Expected:** Clean working directory (except `.env` which should not be committed).

---

## Task 38: Create Final Summary Commit (Optional)

**Files:**
- Summary: Implementation complete

**Step 1: Create empty summary commit**

```bash
git commit --allow-empty -m "feat: migrate from socat to Caddy + Tailscale

BREAKING CHANGE: Containers now require Tailscale for API access.

Major changes:
- Replace socat with Caddy reverse proxy
- Add Tailscale for secure network access
- Remove SSH tunnel functionality
- Add monitoring via Caddy health endpoints and access logs
- Update all documentation with migration guide

Users must:
1. Obtain Tailscale auth key from https://login.tailscale.com/
2. Set TAILSCALE_AUTHKEY environment variable
3. Connect to API via Tailscale network (not localhost)
4. Remove SSH_* environment variables

See docs/MIGRATION_CADDY_TAILSCALE.md for full migration instructions."
```

**Step 2: Review commit history**

```bash
git log --oneline -5
```

**Expected:** Summary commit at top, followed by implementation commits.

---

## Success Criteria

- ✅ Caddy configuration template created
- ✅ Dockerfile installs Caddy and Tailscale (socat/SSH removed)
- ✅ Scripts updated (common.sh, run.sh)
- ✅ Obsolete scripts deleted (run_socat.sh, run_ssh.sh)
- ✅ docker-compose.yml updated with Tailscale/Caddy config
- ✅ .env.example created
- ✅ Documentation updated (README.md, CLAUDE.md)
- ✅ Migration guide created
- ✅ Build succeeds without errors
- ✅ Container starts and connects to Tailscale
- ✅ Health endpoints return 200 OK
- ✅ Graceful shutdown works
- ✅ No SSH/socat references remain in code

## Notes

- **Testing limitation:** Full integration testing requires valid IB Gateway credentials and active Tailscale network
- **Breaking change:** This is a major version change - consider semantic versioning for release
- **Backward compatibility:** Port mappings to localhost retained for backward compatibility, but Tailscale is primary access method
- **Security improvement:** WireGuard encryption + network isolation is more secure than unencrypted socat or SSH tunnels

## Next Steps After Implementation

1. **Test with real IB Gateway credentials** (not demo account)
2. **Test dual mode** (`TRADING_MODE=both`)
3. **Test API connections** from trading applications on Tailscale network
4. **Update CI/CD** for automated builds and testing
5. **Create release** with semantic version bump (e.g., v3.0.0 for breaking change)
6. **Notify users** of breaking changes and migration guide
