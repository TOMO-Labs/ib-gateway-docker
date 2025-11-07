# VPS Deployment Guide - IB Gateway Docker

This guide covers deploying the TOMO-Labs IB Gateway Docker image to a fresh VPS with full CI/CD pipeline, dual trading mode (paper + live), and secure SSH tunnel access.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1: GitHub Repository Setup](#phase-1-github-repository-setup)
3. [Phase 2: VPS Infrastructure Setup](#phase-2-vps-infrastructure-setup)
4. [Phase 3: IB Gateway Deployment](#phase-3-ib-gateway-deployment)
5. [Phase 4: Verification & Testing](#phase-4-verification--testing)
6. [Troubleshooting](#troubleshooting)
7. [Maintenance & Updates](#maintenance--updates)

## Prerequisites

### Interactive Brokers Accounts

- **Paper trading account**: Username and password
- **Live trading account**: Username and password (if using both modes)
- **2FA configured**: Via IBKR Mobile app

### VPS Requirements

- **OS**: Ubuntu 22.04/24.04 LTS or Debian 12
- **RAM**: Minimum 2GB, recommended 4GB for dual mode
- **Disk**: 20GB available space
- **Access**: SSH access with sudo privileges
- **Network**: Outbound internet access on standard ports

### Local Machine Requirements

- Git installed
- GitHub account with access to TOMO-Labs/ib-gateway
- SSH client
- Optional: VNC client for GUI debugging

## Phase 1: GitHub Repository Setup

### Step 1.1: Configure GitHub Container Registry

The workflows are already updated to publish to `ghcr.io/tomo-labs/ib-gateway`. You need to configure GitHub secrets:

1. **Create Personal Access Token**:
   - Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
   - Click "Generate new token (classic)"
   - Select scopes: `write:packages`, `read:packages`, `delete:packages`
   - Copy the token (you'll only see it once)

2. **Add GitHub Secret**:
   - Go to your TOMO-Labs/ib-gateway repository
   - Settings → Secrets and variables → Actions
   - Click "New repository secret"
   - Name: `GHCR_TOKEN`
   - Value: Paste your Personal Access Token
   - Click "Add secret"

3. **Optional: Docker Hub Setup**:
   - If you want to publish to Docker Hub as well:
   - Add secrets: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
   - The workflows already support both registries

### Step 1.2: Build and Publish First Image

**Option A: Tag and Push (Recommended)**

```bash
# On your local machine, in the repository:
git tag v10.41.1c
git push origin v10.41.1c
```

The `publish.yml` workflow will automatically:
- Build multi-arch images (amd64 + arm64)
- Publish to GitHub Container Registry
- Create tags: `latest`, `10.41`, `10.41.1c`

**Option B: Manual Workflow Trigger**

1. Go to GitHub → Actions → "Publish Docker"
2. Click "Run workflow"
3. Select branch: `master`
4. Click "Run workflow"

### Step 1.3: Verify Image Publication

Check that your image was published:

```bash
# View packages in your TOMO-Labs organization
# Go to: https://github.com/orgs/TOMO-Labs/packages

# Or test pull (will download ~1.5GB):
docker pull ghcr.io/tomo-labs/ib-gateway:latest
```

## Phase 2: VPS Infrastructure Setup

### Step 2.1: Initial VPS Setup

SSH into your VPS and run these commands:

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install essential tools
sudo apt install -y curl git vim ufw
```

### Step 2.2: Install Docker

```bash
# Install Docker using official script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh

# Add your user to docker group (replace 'yourusername' with your actual username)
sudo usermod -aG docker $USER

# Install Docker Compose plugin
sudo apt install -y docker-compose-plugin

# Log out and back in for group changes to take effect
exit
```

SSH back in and verify Docker installation:

```bash
docker --version
# Expected: Docker version 24.x.x or higher

docker compose version
# Expected: Docker Compose version v2.x.x or higher
```

### Step 2.3: Configure Firewall

```bash
# Set default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (IMPORTANT: do this before enabling!)
sudo ufw allow ssh

# Enable firewall
sudo ufw enable

# Verify status
sudo ufw status
```

**Security Note**: The IB Gateway API ports (4001, 4002) are bound to localhost only by default, so they're not exposed to the internet. Keep it this way!

### Step 2.4: Create Directory Structure

```bash
# Create application directory
mkdir -p ~/ib-gateway
cd ~/ib-gateway

# Create subdirectories for Docker volumes
mkdir -p ssh logs settings/live settings/paper

# Set appropriate permissions
chmod 700 ssh
chmod 755 logs settings
```

### Step 2.5: Generate SSH Keys (for SSH Tunnel)

```bash
# Generate SSH keypair for tunnel authentication
cd ~/ib-gateway
ssh-keygen -t ed25519 -f ssh/ib_tunnel_key -N ""

# Display public key
cat ssh/ib_tunnel_key.pub
```

**Copy the public key output** - you'll need to add this to your local machine's `~/.ssh/authorized_keys` file.

## Phase 3: IB Gateway Deployment

### Step 3.1: Clone Repository (Optional - for configs only)

```bash
cd ~/ib-gateway

# Clone just the compose file and env example
curl -O https://raw.githubusercontent.com/TOMO-Labs/ib-gateway/master/docker-compose.yml
curl -O https://raw.githubusercontent.com/TOMO-Labs/ib-gateway/master/.env.example

# Or clone the full repository:
# git clone https://github.com/TOMO-Labs/ib-gateway.git .
```

### Step 3.2: Configure Environment Variables

```bash
cd ~/ib-gateway

# Copy example to actual env file
cp .env.example .env

# Edit with your credentials
vim .env
# Or use nano: nano .env
```

**Minimum required configuration** for dual mode:

```bash
# Trading mode
TRADING_MODE=both

# Paper trading credentials
TWS_USERID_PAPER=your_paper_username
TWS_PASSWORD_PAPER=your_paper_password

# Live trading credentials
TWS_USERID=your_live_username
TWS_PASSWORD=your_live_password

# 2FA settings
TWOFA_TIMEOUT_ACTION=restart
RELOGIN_AFTER_TWOFA_TIMEOUT=yes

# Timezone (adjust to your preference)
TIME_ZONE=America/New_York

# Auto-restart (just before midnight)
AUTO_RESTART_TIME=11:59 PM

# SSH Tunnel - REPLACE WITH YOUR INFO
SSH_TUNNEL=yes
SSH_USER_TUNNEL=youruser@your-local-machine.com
SSH_RESTART=yes

# VNC (optional, for debugging)
VNC_SERVER_PASSWORD=your_vnc_password
```

**Secure the .env file**:

```bash
chmod 600 .env
```

### Step 3.3: Configure SSH Tunnel (on your local machine)

On **your local machine** (the one you specified in `SSH_USER_TUNNEL`):

```bash
# Add the VPS public key to authorized_keys
# (The key you got from ssh/ib_tunnel_key.pub on VPS)
echo "ssh-ed25519 AAAA... ib-gateway@vps" >> ~/.ssh/authorized_keys

# Ensure proper permissions
chmod 600 ~/.ssh/authorized_keys
```

**Test the connection** from VPS:

```bash
# On VPS, test SSH connection
ssh -i ~/ib-gateway/ssh/ib_tunnel_key youruser@your-local-machine.com echo "Connection successful"
```

If successful, you'll see "Connection successful" output.

### Step 3.4: Deploy IB Gateway Container

```bash
cd ~/ib-gateway

# Pull the latest image
docker compose pull

# Start in detached mode
docker compose up -d

# View logs
docker compose logs -f
```

**What to look for in logs**:

✅ **Success indicators**:
```
✓ Starting Xvfb...
✓ Starting x11vnc...
✓ Starting IBC for live trading...
✓ Starting IBC for paper trading...
✓ Gateway started successfully
✓ SSH tunnel established
```

❌ **Error indicators**:
```
✗ Login failed
✗ Invalid username or password
✗ 2FA timeout
✗ Could not connect to X server
```

### Step 3.5: Monitor Initial Startup

The first startup takes 2-5 minutes. Monitor progress:

```bash
# Follow logs in real-time
docker compose logs -f

# Check container status
docker compose ps

# Check if both instances are running
docker compose exec ib-gateway ps aux | grep -E "java|ibc"
```

## Phase 4: Verification & Testing

### Step 4.1: Verify Container Health

```bash
# Check container is running
docker compose ps
# Should show: ib-gateway   Up

# Check logs for errors
docker compose logs --tail=100 | grep -i error

# Check API ports are bound
docker compose exec ib-gateway netstat -tlnp | grep -E "4001|4002"
```

### Step 4.2: Test API Connectivity (via SSH Tunnel)

On **your local machine**:

```bash
# The SSH tunnel should now forward ports from VPS to your local machine
# Test paper trading port
telnet localhost 4002
# Or: nc -zv localhost 4002

# Test live trading port
telnet localhost 4001
# Or: nc -zv localhost 4001
```

**Expected result**: Connection succeeds (you can type `^]` then `quit` to exit telnet)

If connection fails, check SSH tunnel status:

```bash
# On local machine
ps aux | grep "ssh.*4001\|ssh.*4002"

# On VPS
docker compose exec ib-gateway ps aux | grep ssh
```

### Step 4.3: Test VNC Access (Optional)

If you set `VNC_SERVER_PASSWORD`, you can view the IB Gateway GUI:

**From local machine**:

```bash
# If you're using SSH tunnel, VNC should be accessible at localhost:5900
# Open your VNC client (like RealVNC, TigerVNC, etc.)
# Connect to: localhost:5900
# Password: Your VNC_SERVER_PASSWORD

# Or use SSH tunnel to forward VNC port:
ssh -L 5900:localhost:5900 user@vps-ip -N
```

You should see the IB Gateway interface with two windows (live and paper).

### Step 4.4: Verify 2FA Handling

**Important**: First-time login from new location requires IB approval:

1. Check logs for 2FA message: `docker compose logs | grep -i "2fa\|second factor"`
2. Open IBKR Mobile app on your phone
3. Approve the login notification
4. Wait for IB Gateway to complete login

The container will automatically handle 2FA timeouts based on your `TWOFA_TIMEOUT_ACTION` setting.

### Step 4.5: Test Trading Application Connection

Use your trading application (TWS API client) to connect:

```python
# Example Python with ib_insync
from ib_insync import IB

ib = IB()

# Connect to paper trading
ib.connect('localhost', 4002, clientId=1)
print(ib.accountValues())
ib.disconnect()

# Connect to live trading
ib.connect('localhost', 4001, clientId=1)
print(ib.accountValues())
ib.disconnect()
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs for errors
docker compose logs

# Check disk space
df -h

# Check memory
free -h

# Restart container
docker compose restart

# Full rebuild (if needed)
docker compose down
docker compose pull
docker compose up -d
```

### Authentication Failures

```bash
# Check credentials in .env
cat .env | grep -E "TWS_USERID|TWS_PASSWORD"

# Verify credentials work by logging into IB website
# https://www.interactivebrokers.com/

# Check for typos or special characters that need escaping
```

### SSH Tunnel Not Working

```bash
# On VPS - check if SSH process is running in container
docker compose exec ib-gateway ps aux | grep ssh

# Check SSH connection from container
docker compose exec ib-gateway ssh -i /home/ibgateway/.ssh/ib_tunnel_key youruser@your-local-machine.com echo "test"

# Check logs for SSH errors
docker compose logs | grep -i ssh

# Restart SSH tunnel
docker compose exec ib-gateway pkill ssh
# Container will auto-restart SSH if SSH_RESTART=yes
```

### API Connection Refused

```bash
# Verify ports are exposed correctly
docker compose ps
# Should show: 0.0.0.0:4001->4003/tcp, 0.0.0.0:4002->4004/tcp

# Check if socat is running (forwards ports from IB Gateway to container interface)
docker compose exec ib-gateway ps aux | grep socat

# Restart socat
docker compose exec ib-gateway pkill socat
# Will auto-restart

# Test from VPS
docker compose exec ib-gateway telnet localhost 4001
docker compose exec ib-gateway telnet localhost 4002
```

### 2FA Timeout Loop

If container keeps restarting due to 2FA:

1. Set `TWOFA_TIMEOUT_ACTION=restart` and `RELOGIN_AFTER_TWOFA_TIMEOUT=yes`
2. Approve login quickly via IBKR Mobile app
3. Consider increasing `TWOFA_EXIT_INTERVAL` to give more time: `TWOFA_EXIT_INTERVAL=120`

### Settings Not Persisting

```bash
# Check volume mounts
docker compose exec ib-gateway ls -la /home/ibgateway/Jts_live
docker compose exec ib-gateway ls -la /home/ibgateway/Jts_paper

# Check host directories
ls -la ~/ib-gateway/settings/live
ls -la ~/ib-gateway/settings/paper

# Fix permissions if needed
docker compose exec ib-gateway chown -R ibgateway:ibgateway /home/ibgateway/Jts_live /home/ibgateway/Jts_paper
```

## Maintenance & Updates

### Update to New IB Gateway Version

When a new version is released and built:

```bash
cd ~/ib-gateway

# Pull latest image
docker compose pull

# Restart with new image
docker compose down
docker compose up -d

# Monitor logs
docker compose logs -f
```

### View Logs

```bash
# Real-time logs
docker compose logs -f

# Last 100 lines
docker compose logs --tail=100

# Save logs to file
docker compose logs > ib-gateway-logs-$(date +%Y%m%d).txt
```

### Backup Configuration

```bash
cd ~/ib-gateway

# Backup .env file
cp .env .env.backup-$(date +%Y%m%d)

# Backup settings
tar -czf settings-backup-$(date +%Y%m%d).tar.gz settings/

# Backup SSH keys
tar -czf ssh-backup-$(date +%Y%m%d).tar.gz ssh/
```

### Restart Container

```bash
# Restart
docker compose restart

# Stop and start
docker compose down
docker compose up -d

# Rebuild (if Dockerfile changed)
docker compose up -d --build
```

### Monitor Resource Usage

```bash
# Container stats
docker stats ib-gateway

# System resources
htop
# Or: top
```

### Auto-Restart Configuration

The container is configured with `restart: always`, so it will automatically restart:
- On VPS reboot
- If the container crashes
- After Docker daemon restarts

To disable auto-restart temporarily:

```bash
docker compose stop
```

To re-enable:

```bash
docker compose start
```

## Security Best Practices

### 1. Credentials Management

- ✅ **DO**: Use `.env` file with `chmod 600` permissions
- ✅ **DO**: Consider Docker secrets for production: `TWS_PASSWORD_FILE`
- ❌ **DON'T**: Commit `.env` to git (it's in `.gitignore`)
- ❌ **DON'T**: Share `.env` or expose credentials

### 2. SSH Keys

- ✅ **DO**: Use passphrase-protected SSH keys when possible
- ✅ **DO**: Rotate SSH keys periodically
- ❌ **DON'T**: Reuse SSH keys across environments

### 3. Network Security

- ✅ **DO**: Keep API ports bound to localhost (`127.0.0.1`)
- ✅ **DO**: Use SSH tunnel for remote access
- ✅ **DO**: Enable firewall (UFW) on VPS
- ❌ **DON'T**: Expose API ports directly to internet
- ❌ **DON'T**: Disable firewall

### 4. VNC Access

- ✅ **DO**: Disable VNC in production (leave `VNC_SERVER_PASSWORD` empty)
- ✅ **DO**: Use strong VNC password if enabled for debugging
- ❌ **DON'T**: Expose VNC port beyond localhost

### 5. System Updates

- ✅ **DO**: Regularly update VPS OS: `sudo apt update && sudo apt upgrade`
- ✅ **DO**: Monitor security advisories
- ✅ **DO**: Keep Docker updated

## Alternative: Local-to-VPS SSH Tunnel

If you prefer to initiate the tunnel from your local machine (instead of container-initiated):

**On VPS** (in `.env`):
```bash
SSH_TUNNEL=no
```

**On your local machine**:
```bash
# Create SSH tunnel
ssh -L 4001:localhost:4001 -L 4002:localhost:4002 -L 5900:localhost:5900 user@vps-ip -N

# Or use autossh for automatic reconnection
autossh -M 0 -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" \
  -L 4001:localhost:4001 -L 4002:localhost:4002 -L 5900:localhost:5900 \
  user@vps-ip -N
```

This approach:
- ✅ Simpler firewall configuration
- ✅ Standard SSH tunnel pattern
- ❌ Requires keeping local machine running
- ❌ More manual setup

## Additional Resources

- [IB Gateway Docker README](../README.md)
- [Interactive Brokers API Documentation](https://interactivebrokers.github.io/tws-api/)
- [IBC Documentation](https://github.com/IbcAlpha/IBC/blob/master/userguide.md)
- [Docker Compose Documentation](https://docs.docker.com/compose/)

## Support

For issues specific to this Docker image:
- GitHub Issues: https://github.com/TOMO-Labs/ib-gateway/issues

For Interactive Brokers API issues:
- IB API Forum: https://groups.io/g/twsapi

For general Docker questions:
- Docker Documentation: https://docs.docker.com/
