# Caddy + Tailscale Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace socat with Caddy reverse proxy and add Tailscale network isolation for IB Gateway Docker containers.

**Architecture:** Install Caddy + Tailscale in containers, bind Caddy to Tailscale IP only, remove socat and SSH tunnel code. Security via WireGuard encryption, monitoring via Caddy logs and health endpoints.

**Tech Stack:** Caddy (reverse proxy), Tailscale (WireGuard VPN), Docker, Bash scripting, envsubst (template processing)

---

## Task 1: Create Caddy Configuration Template

**Files:**
- Create: `image-files/config/caddy/Caddyfile.tmpl`

**Step 1: Create directory structure**

```bash
mkdir -p image-files/config/caddy
```

**Step 2: Write Caddyfile template**

Create `image-files/config/caddy/Caddyfile.tmpl` with this content:

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
git add image-files/config/caddy/Caddyfile.tmpl
git commit -m "feat: add Caddy configuration template"
```

---

## Task 2: Update Dockerfile Template (ib-gateway)

**Files:**
- Modify: `Dockerfile.template`

**Step 1: Remove socat and SSH packages**

Find this line (around line 93):
```dockerfile
apt-get install --no-install-recommends --yes \
    gettext-base socat xvfb x11vnc sshpass openssh-client sudo telnet
```

Replace with:
```dockerfile
apt-get install --no-install-recommends --yes \
    gettext-base xvfb x11vnc sudo telnet curl gnupg
```

**Step 2: Add Caddy installation**

After the apt-get install block (around line 95), add:

```dockerfile
# Install Caddy
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
    gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
    tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install --no-install-recommends --yes caddy
```

**Step 3: Add Tailscale installation**

After the Caddy installation block, add:

```dockerfile
# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh
```

**Step 4: Create Caddy log directory**

Find the section where directories are created (around line 100-110), and add:

```dockerfile
RUN mkdir -p /var/log/caddy && \
    chown ibgateway:ibgateway /var/log/caddy
```

**Step 5: Copy Caddy config template**

Find the COPY commands section (around line 120-130), and add:

```dockerfile
COPY config/caddy /home/ibgateway/caddy-config
```

**Step 6: Commit**

```bash
git add Dockerfile.template
git commit -m "feat: replace socat with Caddy and Tailscale in ib-gateway Dockerfile"
```

---

## Task 3: Update Dockerfile Template (tws-rdesktop)

**Files:**
- Modify: `Dockerfile.tws.template`

**Step 1: Remove socat and SSH packages**

Find this line (around line 43):
```dockerfile
apt-get install --no-install-recommends --yes socat sshpass gettext-base \
    libnspr4 libnss3 libcrypto++8 xdg-utils ...
```

Replace `socat sshpass` with `curl gnupg`:
```dockerfile
apt-get install --no-install-recommends --yes curl gnupg gettext-base \
    libnspr4 libnss3 libcrypto++8 xdg-utils ...
```

**Step 2: Add Caddy installation**

After the apt-get install block, add:

```dockerfile
# Install Caddy
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
    gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
    tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install --no-install-recommends --yes caddy
```

**Step 3: Add Tailscale installation**

After the Caddy installation, add:

```dockerfile
# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh
```

**Step 4: Create Caddy log directory**

Add after directory creation section:

```dockerfile
RUN mkdir -p /var/log/caddy && \
    chown abc:abc /var/log/caddy
```

**Step 5: Copy Caddy config template**

Find the COPY commands section and add:

```dockerfile
COPY config/caddy /opt/caddy-config
```

**Step 6: Commit**

```bash
git add Dockerfile.tws.template
git commit -m "feat: replace socat with Caddy and Tailscale in tws-rdesktop Dockerfile"
```

---

## Task 4: Add Tailscale Startup Functions to common.sh

**Files:**
- Modify: `image-files/scripts/common.sh`

**Step 1: Add start_tailscale function**

Add this function before the `port_forwarding()` function (around line 140):

```bash
start_tailscale() {
    echo "Starting Tailscale daemon..."

    # Create state directory if it doesn't exist
    mkdir -p /var/lib/tailscale

    # Start tailscaled in background with userspace networking
    tailscaled --tun=userspace-networking --state=/var/lib/tailscale/state.conf &
    sleep 2

    # Bring up Tailscale network
    echo "Connecting to Tailscale network..."
    local hostname="${TAILSCALE_HOSTNAME:-$(hostname)}"

    if [ -z "$TAILSCALE_AUTHKEY" ]; then
        echo "ERROR: TAILSCALE_AUTHKEY environment variable is required"
        exit 1
    fi

    tailscale up --authkey="${TAILSCALE_AUTHKEY}" \
                 --hostname="${hostname}" \
                 ${TAILSCALE_EXTRA_ARGS}

    # Wait for Tailscale IP
    echo "Waiting for Tailscale IP..."
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
        echo "ERROR: Failed to obtain Tailscale IP after ${max_attempts} seconds"
        exit 1
    fi

    export TAILSCALE_IP
    echo "Tailscale connected with IP: ${TAILSCALE_IP}"
}
```

**Step 2: Add start_caddy function**

Add this function after `start_tailscale()`:

```bash
start_caddy() {
    echo "Starting Caddy reverse proxy..."

    if [ -z "$TAILSCALE_IP" ]; then
        echo "ERROR: TAILSCALE_IP not set. Run start_tailscale first."
        exit 1
    fi

    # Determine config template path based on user
    if [ "$(whoami)" = "ibgateway" ]; then
        local config_template="/home/ibgateway/caddy-config/Caddyfile.tmpl"
        local config_output="/etc/caddy/Caddyfile"
    else
        local config_template="/opt/caddy-config/Caddyfile.tmpl"
        local config_output="/etc/caddy/Caddyfile"
    fi

    # Set default log level if not specified
    export CADDY_LOG_LEVEL="${CADDY_LOG_LEVEL:-INFO}"

    # Generate Caddyfile from template
    if [ -f "$config_template" ]; then
        envsubst < "$config_template" > "$config_output"
        echo "Generated Caddy config at ${config_output}"
    else
        echo "ERROR: Caddy config template not found at ${config_template}"
        exit 1
    fi

    # Start Caddy in background
    caddy run --config "$config_output" &
    sleep 1

    echo "Caddy started successfully"
}
```

**Step 3: Commit**

```bash
git add image-files/scripts/common.sh
git commit -m "feat: add Tailscale and Caddy startup functions"
```

---

## Task 5: Replace port_forwarding Function in common.sh

**Files:**
- Modify: `image-files/scripts/common.sh`

**Step 1: Find and replace port_forwarding function**

Find the `port_forwarding()` function (around line 143-164). Replace the entire function with:

```bash
port_forwarding() {
    echo "Setting up port forwarding with Caddy..."

    # Start Tailscale first
    start_tailscale

    # Export port variables for Caddy config
    export PUBLISHED_PORT="${SOCAT_PORT}"
    export LOCAL_PORT="${API_PORT}"

    # Start Caddy
    start_caddy

    echo "Port forwarding setup complete"
    echo "  Local API: 127.0.0.1:${LOCAL_PORT}"
    echo "  Published: ${TAILSCALE_IP}:${PUBLISHED_PORT}"
}
```

**Step 2: Remove start_socat function**

Find and delete the `start_socat()` function (around line 250-264):

```bash
# DELETE THIS ENTIRE FUNCTION
start_socat() {
    if [ -n "$(pgrep -f "fork TCP:127.0.0.1:${API_PORT}")" ]; then
        echo ".> socat already active. Not starting a new one"
        return 0
    else
        "${SCRIPT_PATH}/run_socat.sh" &
    fi
}
```

**Step 3: Remove start_ssh function**

Find and delete the `start_ssh()` function (if it exists):

```bash
# DELETE THIS ENTIRE FUNCTION
start_ssh() {
    # ... SSH tunnel code
}
```

**Step 4: Commit**

```bash
git add image-files/scripts/common.sh
git commit -m "refactor: replace socat/SSH port forwarding with Caddy"
```

---

## Task 6: Update stop_ibc Function in run.sh

**Files:**
- Modify: `image-files/scripts/run.sh`

**Step 1: Find stop_ibc function**

Locate the `stop_ibc()` function (around line 26-37).

**Step 2: Replace process termination logic**

Replace the SSH/socat termination code with Caddy/Tailscale:

```bash
stop_ibc() {
    echo "Shutting down services..."

    # Stop Caddy
    pkill caddy

    # Stop Tailscale
    pkill tailscaled

    # Stop IBC
    pkill -9 -f "/home/ibgateway/ibc/scripts/ibcstart.sh"

    # Stop Xvfb
    pkill Xvfb

    # Stop VNC (if running)
    pkill x11vnc

    echo "Services stopped"
}
```

**Step 3: Commit**

```bash
git add image-files/scripts/run.sh
git commit -m "refactor: update shutdown handler for Caddy/Tailscale"
```

---

## Task 7: Update stop_ibc Function in run_tws.sh

**Files:**
- Modify: `image-files/tws-scripts/run_tws.sh`

**Step 1: Find stop_ibc function**

Locate the `stop_ibc()` function in the TWS script.

**Step 2: Replace process termination logic**

Similar to run.sh, replace SSH/socat with Caddy/Tailscale:

```bash
stop_ibc() {
    echo "Shutting down services..."

    # Stop Caddy
    pkill caddy

    # Stop Tailscale
    pkill tailscaled

    # Stop IBC
    pkill -9 -f "/opt/ibc/scripts/ibcstart.sh"

    # Stop other services as needed

    echo "Services stopped"
}
```

**Step 3: Commit**

```bash
git add image-files/tws-scripts/run_tws.sh
git commit -m "refactor: update TWS shutdown handler for Caddy/Tailscale"
```

---

## Task 8: Delete Obsolete Scripts

**Files:**
- Delete: `image-files/scripts/run_socat.sh`
- Delete: `image-files/scripts/run_ssh.sh`

**Step 1: Delete run_socat.sh**

```bash
rm image-files/scripts/run_socat.sh
```

**Step 2: Delete run_ssh.sh**

```bash
rm image-files/scripts/run_ssh.sh
```

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove obsolete socat and SSH tunnel scripts"
```

---

## Task 9: Update docker-compose.yml

**Files:**
- Modify: `docker-compose.yml`

**Step 1: Add Tailscale environment variables**

Find the `environment:` section (around line 15-50) and add:

```yaml
environment:
  # Tailscale configuration
  - TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY}
  - TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-ib-gateway}
  - TAILSCALE_TAGS=${TAILSCALE_TAGS:-}
  - TAILSCALE_EXTRA_ARGS=${TAILSCALE_EXTRA_ARGS:-}

  # Caddy configuration
  - CADDY_LOG_LEVEL=${CADDY_LOG_LEVEL:-INFO}
  - ENABLE_HEALTH_CHECK=${ENABLE_HEALTH_CHECK:-yes}

  # Existing variables continue...
```

**Step 2: Remove SSH environment variables**

Find and remove these lines (if present):
```yaml
  - SSH_TUNNEL=${SSH_TUNNEL:-no}
  - SSH_USER_TUNNEL=${SSH_USER_TUNNEL:-}
  - SSH_OPTIONS=${SSH_OPTIONS:-}
  - SSH_REMOTE_PORT=${SSH_REMOTE_PORT:-}
  - SSH_ALIVE_INTERVAL=${SSH_ALIVE_INTERVAL:-20}
  - SSH_ALIVE_COUNT=${SSH_ALIVE_COUNT:-3}
  - SSH_PASSPHRASE=${SSH_PASSPHRASE:-}
  - SSH_RESTART=${SSH_RESTART:-5}
  - SSH_VNC_PORT=${SSH_VNC_PORT:-}
```

**Step 3: Add volume mounts**

Find the `volumes:` section (around line 45-50) and add:

```yaml
volumes:
  - ./tws_settings:/home/ibgateway/Jts
  - tailscale-state:/var/lib/tailscale
  - caddy-logs:/var/log/caddy
```

**Step 4: Add volume definitions**

At the end of the file, add:

```yaml
volumes:
  tailscale-state:
  caddy-logs:
```

**Step 5: Update comments for port mappings**

Update the comment above the `ports:` section to reflect Tailscale access:

```yaml
# Port mappings: For backward compatibility. Primary access via Tailscale network.
# Connect to: <tailscale-hostname>.ts.net:4003 or <tailscale-ip>:4003
ports:
  - "127.0.0.1:4001:4003"  # Live trading API
  - "127.0.0.1:4002:4004"  # Paper trading API
  - "127.0.0.1:5900:5900"  # VNC
```

**Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Tailscale/Caddy config to docker-compose"
```

---

## Task 10: Update tws-docker-compose.yml

**Files:**
- Modify: `tws-docker-compose.yml`

**Step 1: Add Tailscale environment variables**

Similar to Task 9, add to the `environment:` section:

```yaml
environment:
  # Tailscale configuration
  - TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY}
  - TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-tws-rdesktop}
  - TAILSCALE_TAGS=${TAILSCALE_TAGS:-}
  - TAILSCALE_EXTRA_ARGS=${TAILSCALE_EXTRA_ARGS:-}

  # Caddy configuration
  - CADDY_LOG_LEVEL=${CADDY_LOG_LEVEL:-INFO}
  - ENABLE_HEALTH_CHECK=${ENABLE_HEALTH_CHECK:-yes}

  # Existing variables continue...
```

**Step 2: Remove SSH environment variables**

Remove all `SSH_*` variables as in Task 9.

**Step 3: Add volume mounts**

Add to `volumes:` section:

```yaml
volumes:
  - ./tws_settings:/config/tws_settings
  - tailscale-state:/var/lib/tailscale
  - caddy-logs:/var/log/caddy
```

**Step 4: Add volume definitions**

At the end of the file:

```yaml
volumes:
  tailscale-state:
  caddy-logs:
```

**Step 5: Update port mapping comments**

```yaml
# Port mappings: For backward compatibility. Primary access via Tailscale network.
# Connect to: <tailscale-hostname>.ts.net:7498 or <tailscale-ip>:7498
ports:
  - "127.0.0.1:7496:7498"  # Live trading API
  - "127.0.0.1:7497:7499"  # Paper trading API
  - "127.0.0.1:3370:3389"  # RDP
```

**Step 6: Commit**

```bash
git add tws-docker-compose.yml
git commit -m "feat: add Tailscale/Caddy config to tws-docker-compose"
```

---

## Task 11: Create Example .env File

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
ENABLE_HEALTH_CHECK=yes

# IB Gateway Configuration
TRADING_MODE=paper
TWS_USERID=your_username
TWS_PASSWORD=your_password
VNC_SERVER_PASSWORD=vnc_password

# For dual mode (TRADING_MODE=both)
# TWS_USERID_PAPER=paper_username
# TWS_PASSWORD_PAPER=paper_password
```

**Step 2: Commit**

```bash
git add .env.example
git commit -m "docs: add example environment file with Tailscale config"
```

---

## Task 12: Update README.md - Remove SSH Tunnel Documentation

**Files:**
- Modify: `README.md`

**Step 1: Find and remove SSH tunnel section**

Search for sections mentioning "SSH", "SSH Tunnel", or "SSH_TUNNEL" and remove them.

Typical locations:
- Environment variables table
- Configuration examples
- Security section

**Step 2: Find and remove socat references**

Search for "socat" and update or remove those sections. Replace with Caddy references where appropriate.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: remove SSH tunnel and socat references from README"
```

---

## Task 13: Update README.md - Add Tailscale Documentation

**Files:**
- Modify: `README.md`

**Step 1: Add Tailscale setup section**

Add a new section after the "Quick Start" or "Configuration" section:

```markdown
## Tailscale Setup

This container requires Tailscale for secure network access to the IB Gateway API.

### Prerequisites

1. Create a Tailscale account at https://login.tailscale.com/
2. Generate an auth key:
   - Go to Settings > Keys in the Tailscale admin console
   - Create a new auth key
   - Enable "Reusable" and "Ephemeral" (recommended)
   - Copy the key (starts with `tskey-auth-`)

### Configuration

Set the following environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TAILSCALE_AUTHKEY` | Yes | - | Tailscale authentication key |
| `TAILSCALE_HOSTNAME` | No | container hostname | Custom hostname for your tailnet |
| `TAILSCALE_TAGS` | No | - | Tailscale ACL tags (e.g., `tag:trading`) |
| `TAILSCALE_EXTRA_ARGS` | No | - | Additional arguments for `tailscale up` |
| `CADDY_LOG_LEVEL` | No | `INFO` | Log level: DEBUG, INFO, WARN, ERROR |

### Connecting to the API

After the container starts, connect to the IB API using your Tailscale network:

**Using Tailscale hostname:**
```python
from ib_insync import IB
ib = IB()
ib.connect('ib-gateway.your-tailnet.ts.net', 4003, clientId=1)
```

**Using Tailscale IP:**
```bash
# Get the container's Tailscale IP
docker exec <container-name> tailscale ip -4
```

```python
ib.connect('100.64.x.x', 4003, clientId=1)
```

### Port Mappings

| Container Port | Purpose | Access Method |
|----------------|---------|---------------|
| 4003 | Live trading API | Via Tailscale network |
| 4004 | Paper trading API | Via Tailscale network |
| 5900 | VNC (optional) | localhost or Tailscale |
| 2019 | Health checks | Internal only |

### Security

- All traffic is encrypted via WireGuard (Tailscale's protocol)
- API is only accessible from devices on your Tailscale network
- No public internet exposure
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add Tailscale setup and usage documentation"
```

---

## Task 14: Update README.md - Add Monitoring Section

**Files:**
- Modify: `README.md`

**Step 1: Add monitoring documentation**

Add a new section for Caddy monitoring:

```markdown
## Monitoring

### Health Checks

Caddy provides health check endpoints accessible from within the container:

```bash
# Check health
docker exec <container-name> curl http://localhost:2019/health

# Check readiness
docker exec <container-name> curl http://localhost:2019/ready
```

You can integrate these with Docker's HEALTHCHECK:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD curl -f http://localhost:2019/health || exit 1
```

### Access Logs

Caddy logs all API connections to `/var/log/caddy/`:

```bash
# View live logs
docker exec <container-name> tail -f /var/log/caddy/access-live.log

# View paper trading logs (if TRADING_MODE=both)
docker exec <container-name> tail -f /var/log/caddy/access-paper.log
```

### Tailscale Status

Check Tailscale connectivity:

```bash
# View Tailscale status
docker exec <container-name> tailscale status

# Get Tailscale IP
docker exec <container-name> tailscale ip -4

# Network diagnostics
docker exec <container-name> tailscale netcheck
```
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add monitoring and health check documentation"
```

---

## Task 15: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update "Key Components" section**

Find the "Key Components" section at the top and update:

```markdown
**Key Components:**
- IB Gateway/TWS: Interactive Brokers trading platforms
- IBC (Interactive Brokers Controller): Automates user interactions with IB Gateway/TWS
- Xvfb: Virtual framebuffer for running GUI applications headlessly
- x11vnc: Optional VNC server for remote GUI access (ib-gateway only)
- Caddy: Reverse proxy for API port forwarding with monitoring
- Tailscale: WireGuard VPN for secure network access
- xrdp/xfce: Desktop environment for TWS
```

**Step 2: Update "Port Forwarding Architecture" section**

Replace the socat description with:

```markdown
## Port Forwarding Architecture

**Why Caddy is needed:**
IB Gateway/TWS binds API ports to `127.0.0.1` (localhost only) inside the container for security. To make these ports accessible to other containers or the host, Caddy proxies connections:

- IB Gateway: `127.0.0.1:4001` → Caddy on `${TAILSCALE_IP}:4003`, `127.0.0.1:4002` → `${TAILSCALE_IP}:4004`
- TWS: `127.0.0.1:7496` → Caddy on `${TAILSCALE_IP}:7498`, `127.0.0.1:7497` → `${TAILSCALE_IP}:7499`

Caddy binds only to the Tailscale IP, ensuring the API is accessible only from the Tailscale network.

**Tailscale Network Security:**
All traffic is encrypted via WireGuard. Only devices on your Tailscale network can access the IB API.
```

**Step 3: Remove SSH tunnel references**

Find and remove the "SSH Tunnel Alternative" section and any other SSH-related content.

**Step 4: Update "Security Considerations" section**

Update to reflect Tailscale security:

```markdown
## Security Considerations

**Critical security notes:**
- IB API uses unencrypted, unauthenticated TCP sockets at the application layer
- Tailscale encrypts all traffic via WireGuard at the network layer
- API only accessible from devices on your Tailscale network
- Never expose API ports to untrusted networks
- Use Tailscale ACLs to further restrict access
- Credential files (`_FILE` variables) support Docker secrets for production deployments
```

**Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for Caddy/Tailscale architecture"
```

---

## Task 16: Run update.sh for Stable Channel

**Files:**
- Generates: `stable/` directory contents

**Step 1: Check current stable version**

```bash
git log --oneline --all | grep "Update.*stable" | head -1
```

Note the version number (e.g., `10.40.1d`).

**Step 2: Run update.sh for stable**

```bash
./update.sh stable <version>
```

Replace `<version>` with the version noted in Step 1.

**Step 3: Verify generated files**

Check that these files were updated:
- `stable/Dockerfile`
- `stable/Dockerfile.tws`
- `stable/config/caddy/Caddyfile.tmpl` (new)
- `stable/scripts/common.sh`
- `stable/scripts/run.sh`

Verify that these files were removed:
- `stable/scripts/run_socat.sh` (should not exist)
- `stable/scripts/run_ssh.sh` (should not exist)

**Step 4: Commit**

```bash
git add stable/
git commit -m "build: regenerate stable channel with Caddy/Tailscale"
```

---

## Task 17: Run update.sh for Latest Channel

**Files:**
- Generates: `latest/` directory contents

**Step 1: Check current latest version**

```bash
git log --oneline --all | grep "Update.*latest" | head -1
```

Note the version number (e.g., `10.41.1c`).

**Step 2: Run update.sh for latest**

```bash
./update.sh latest <version>
```

Replace `<version>` with the version noted in Step 1.

**Step 3: Verify generated files**

Check that these files were updated:
- `latest/Dockerfile`
- `latest/Dockerfile.tws`
- `latest/config/caddy/Caddyfile.tmpl` (new)
- `latest/scripts/common.sh`
- `latest/scripts/run.sh`

Verify that these files were removed:
- `latest/scripts/run_socat.sh` (should not exist)
- `latest/scripts/run_ssh.sh` (should not exist)

**Step 4: Commit**

```bash
git add latest/
git commit -m "build: regenerate latest channel with Caddy/Tailscale"
```

---

## Task 18: Test Build (ib-gateway)

**Files:**
- Tests: Build system

**Step 1: Ensure you have a Tailscale auth key**

If you don't have one, visit https://login.tailscale.com/admin/settings/keys

Create a reusable, ephemeral auth key for testing.

**Step 2: Create .env file for testing**

```bash
cat > .env << 'EOF'
TAILSCALE_AUTHKEY=tskey-auth-your-test-key
TAILSCALE_HOSTNAME=ib-gateway-test
TWS_USERID=your_test_username
TWS_PASSWORD=your_test_password
TRADING_MODE=paper
VNC_SERVER_PASSWORD=test123
EOF
```

**Step 3: Build the container**

```bash
docker compose build
```

Expected: Build succeeds without errors. Watch for:
- Caddy installation succeeds
- Tailscale installation succeeds
- No errors about missing socat

**Step 4: Start the container**

```bash
docker compose up -d
```

**Step 5: Check logs**

```bash
docker compose logs -f
```

Expected output should include:
- "Starting Tailscale daemon..."
- "Connecting to Tailscale network..."
- "Tailscale connected with IP: 100.x.x.x"
- "Starting Caddy reverse proxy..."
- "Caddy started successfully"

**Step 6: Verify Tailscale connectivity**

```bash
docker exec ib-gateway-1 tailscale status
```

Expected: Shows device online with IP address.

**Step 7: Verify Caddy health endpoint**

```bash
docker exec ib-gateway-1 curl http://localhost:2019/health
```

Expected: Returns "OK" with 200 status.

**Step 8: Get Tailscale IP**

```bash
docker exec ib-gateway-1 tailscale ip -4
```

Note the IP (e.g., `100.64.1.2`).

**Step 9: Stop container**

```bash
docker compose down
```

**Step 10: Document test results**

If all tests pass, document in commit message. If issues found, document and fix before continuing.

---

## Task 19: Test Build (tws-rdesktop)

**Files:**
- Tests: TWS build system

**Step 1: Update .env for TWS testing**

```bash
cat > .env << 'EOF'
TAILSCALE_AUTHKEY=tskey-auth-your-test-key
TAILSCALE_HOSTNAME=tws-test
TWS_USERID=your_test_username
TWS_PASSWORD=your_test_password
TRADING_MODE=paper
PASSWD=test123
EOF
```

**Step 2: Build TWS container**

```bash
docker compose -f tws-docker-compose.yml build
```

Expected: Build succeeds with Caddy and Tailscale installed.

**Step 3: Start the container**

```bash
docker compose -f tws-docker-compose.yml up -d
```

**Step 4: Check logs**

```bash
docker compose -f tws-docker-compose.yml logs -f
```

Expected: Similar Tailscale and Caddy startup messages.

**Step 5: Verify Tailscale connectivity**

```bash
docker exec tws-rdesktop-1 tailscale status
```

**Step 6: Verify Caddy health endpoint**

```bash
docker exec tws-rdesktop-1 curl http://localhost:2019/health
```

**Step 7: Stop container**

```bash
docker compose -f tws-docker-compose.yml down
```

**Step 8: Document results**

If tests pass, we're ready for the final commit.

---

## Task 20: Create Migration Guide

**Files:**
- Create: `docs/MIGRATION_CADDY_TAILSCALE.md`

**Step 1: Create migration guide**

Create `docs/MIGRATION_CADDY_TAILSCALE.md`:

```markdown
# Migration Guide: socat to Caddy + Tailscale

This guide helps existing users migrate from socat-based containers to the new Caddy + Tailscale architecture.

## Breaking Changes

### What Changed

1. **socat removed** → Replaced with Caddy reverse proxy
2. **SSH tunnels removed** → Replaced with Tailscale WireGuard VPN
3. **New requirement:** Tailscale auth key needed
4. **Connection method changed:** Connect via Tailscale network, not localhost

### What Stayed the Same

- IB Gateway/TWS functionality unchanged
- IB API protocol unchanged
- Port numbers unchanged (4001/4002 for ib-gateway, 7496/7497 for TWS)
- VNC/RDP access unchanged
- Docker Compose structure similar

## Prerequisites

1. **Tailscale account:** Sign up at https://tailscale.com/
2. **Auth key:** Generate from https://login.tailscale.com/admin/settings/keys
   - Enable "Reusable" (allows multiple containers)
   - Enable "Ephemeral" (auto-removes offline devices)
   - Copy the key (starts with `tskey-auth-`)

## Migration Steps

### Step 1: Update Your docker-compose.yml

Add Tailscale environment variables:

```yaml
environment:
  - TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY}
  - TAILSCALE_HOSTNAME=ib-gateway  # or tws-rdesktop
```

Remove SSH-related variables (if present):
```yaml
  # Remove these:
  # - SSH_TUNNEL=yes
  # - SSH_USER_TUNNEL=...
  # etc.
```

Add volume mounts:

```yaml
volumes:
  - tailscale-state:/var/lib/tailscale
  - caddy-logs:/var/log/caddy
  # ... existing volumes
```

Add volume definitions:

```yaml
volumes:
  tailscale-state:
  caddy-logs:
```

### Step 2: Update Your .env File

Add:
```bash
TAILSCALE_AUTHKEY=tskey-auth-your-key-here
```

Remove:
```bash
# Remove these if present:
# SSH_TUNNEL=yes
# SSH_USER_TUNNEL=...
```

### Step 3: Install Tailscale on Your Client

Install Tailscale on the machine running your trading application:

- **Mac:** `brew install tailscale`
- **Linux:** https://tailscale.com/download/linux
- **Windows:** https://tailscale.com/download/windows

Start Tailscale:
```bash
sudo tailscale up
```

### Step 4: Pull New Image

```bash
docker compose pull
```

### Step 5: Start Container

```bash
docker compose up -d
```

### Step 6: Find Tailscale IP

```bash
docker exec <container-name> tailscale ip -4
```

Or use the Tailscale hostname: `ib-gateway.your-tailnet.ts.net`

### Step 7: Update Your Trading Application

Change connection from:
```python
ib.connect('127.0.0.1', 4001, clientId=1)
```

To:
```python
ib.connect('ib-gateway.your-tailnet.ts.net', 4003, clientId=1)
# or
ib.connect('100.64.x.x', 4003, clientId=1)  # Use IP from Step 6
```

Note the port change:
- Live: 4001 (localhost) → 4003 (Tailscale)
- Paper: 4002 (localhost) → 4004 (Tailscale)

### Step 8: Test Connection

Run your trading application and verify it connects successfully.

### Step 9: Monitor Logs

Check Caddy access logs:
```bash
docker exec <container-name> tail -f /var/log/caddy/access-live.log
```

## Troubleshooting

### Container fails to start with "TAILSCALE_AUTHKEY not set"

**Solution:** Add `TAILSCALE_AUTHKEY` to your `.env` file.

### Cannot connect to IB API from trading application

**Checks:**
1. Is Tailscale running on your client? `tailscale status`
2. Is the container connected? `docker exec <container> tailscale status`
3. Can you ping the container? `ping ib-gateway.your-tailnet.ts.net`
4. Check Caddy logs: `docker exec <container> cat /var/log/caddy/access-live.log`

### "Tailscale IP not obtained after 30 seconds"

**Possible causes:**
- Invalid auth key
- Network connectivity issues
- Tailscale service unavailable

**Solution:**
1. Check auth key is valid (not expired)
2. Check container logs: `docker compose logs`
3. Verify network connectivity

### SSH tunnel setup no longer works

**Solution:** SSH tunnels have been removed. Use Tailscale instead:
- All traffic encrypted via WireGuard
- More reliable than SSH tunnels
- Built-in ACL support

## Rollback Plan

If you need to rollback to the old version:

```bash
# Stop new container
docker compose down

# Use old image tag (if available)
docker compose pull ghcr.io/extsoft/ib-gateway:10.40.1d  # example old version

# Update docker-compose.yml image version
# Remove Tailscale environment variables
# Add back SSH variables if needed

# Start old container
docker compose up -d
```

## Benefits of New Architecture

1. **Better security:** WireGuard encryption, network isolation
2. **Better monitoring:** Access logs, health checks, metrics endpoints
3. **Simpler codebase:** No SSH tunnel complexity
4. **Modern tooling:** Caddy and Tailscale actively maintained
5. **ACL support:** Fine-grained access control via Tailscale ACLs

## Need Help?

- GitHub Issues: https://github.com/extsoft/ib-gateway-docker/issues
- Tailscale docs: https://tailscale.com/kb/
- Caddy docs: https://caddyserver.com/docs/
```

**Step 2: Commit**

```bash
git add docs/MIGRATION_CADDY_TAILSCALE.md
git commit -m "docs: add migration guide for Caddy/Tailscale"
```

---

## Task 21: Final Verification and Summary

**Step 1: Review all changes**

```bash
git log --oneline --decorate --graph -20
```

Verify you have commits for:
- Caddy config template
- Dockerfile updates (both templates)
- Script updates (common.sh, run.sh, run_tws.sh)
- Deleted obsolete scripts
- Docker compose updates
- Documentation updates
- Channel regeneration (stable and latest)
- Migration guide

**Step 2: Create summary commit message**

If you want a final summary commit:

```bash
git commit --allow-empty -m "feat: migrate from socat to Caddy + Tailscale

BREAKING CHANGE: Containers now require Tailscale for API access.

- Replace socat with Caddy reverse proxy
- Add Tailscale for secure network access
- Remove SSH tunnel functionality
- Add monitoring via Caddy health endpoints and access logs
- Update documentation with migration guide

Users must:
1. Obtain Tailscale auth key
2. Set TAILSCALE_AUTHKEY environment variable
3. Connect to API via Tailscale network
4. Remove SSH_* environment variables

See docs/MIGRATION_CADDY_TAILSCALE.md for full migration instructions."
```

**Step 3: Document remaining work**

Note any items that need manual testing or CI/CD updates:
- Multi-arch builds (amd64/arm64) in GitHub Actions
- Integration testing with real IB Gateway credentials
- Documentation review by project maintainer

---

## Notes

- **Testing limitation:** Full integration testing requires valid IB Gateway credentials and Tailscale network
- **CI/CD:** GitHub Actions workflows may need updates for multi-arch builds
- **Breaking change:** This is a major version change - consider semantic versioning

## Success Criteria

- ✅ All template files updated
- ✅ Both Dockerfiles install Caddy and Tailscale
- ✅ socat and SSH code removed
- ✅ Docker compose files updated
- ✅ Both channels regenerated (stable and latest)
- ✅ Documentation updated
- ✅ Migration guide created
- ✅ Local builds succeed
- ✅ Container starts and connects to Tailscale
- ✅ Health endpoints functional
