# VPS Deployment Checklist

Quick reference checklist for deploying your TOMO-Labs IB Gateway fork to a VPS.

## Pre-Deployment (Local Machine)

### 1. GitHub Setup

- [ ] Create GitHub Personal Access Token (PAT)
  - Go to: GitHub Settings → Developer settings → Personal access tokens
  - Scopes: `write:packages`, `read:packages`

- [ ] Add PAT to repository secrets
  - Repository: Settings → Secrets and variables → Actions
  - Secret name: `GHCR_TOKEN`
  - Value: Your PAT

- [ ] Trigger first image build
  ```bash
  git tag v10.41.1c
  git push origin v10.41.1c
  ```

- [ ] Verify image published
  - Check: https://github.com/orgs/TOMO-Labs/packages

### 2. Prepare IB Credentials

- [ ] Paper trading account credentials (if using)
- [ ] Live trading account credentials
- [ ] IBKR Mobile app installed for 2FA

## VPS Setup

### 3. Run Automated Setup Script

```bash
# Download and run the setup script
curl -fsSL https://raw.githubusercontent.com/TOMO-Labs/ib-gateway/master/scripts/vps-setup.sh -o vps-setup.sh
bash vps-setup.sh
```

This script will:
- [ ] Update system packages
- [ ] Install Docker and Docker Compose
- [ ] Configure UFW firewall
- [ ] Create directory structure
- [ ] Generate SSH keys
- [ ] Download docker-compose.yml and .env.example

### 4. Configure SSH Tunnel

**On VPS**, the script will show your public key. Copy it.

**On your local machine** (where you'll run trading apps):
```bash
# Add VPS public key to authorized_keys
echo "ssh-ed25519 AAAA... ib-gateway@vps" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**Test connection from VPS:**
```bash
ssh -i ~/ib-gateway/ssh/ib_tunnel_key youruser@your-local-machine.com echo "Success"
```

### 5. Configure Environment

**On VPS:**
```bash
cd ~/ib-gateway
vim .env
```

**Minimal configuration for live trading:**
```bash
TRADING_MODE=live
TWS_USERID=your_live_username
TWS_PASSWORD=your_live_password
TWOFA_TIMEOUT_ACTION=restart
RELOGIN_AFTER_TWOFA_TIMEOUT=yes
TIME_ZONE=America/New_York
AUTO_RESTART_TIME=11:59 PM
SSH_TUNNEL=yes
SSH_USER_TUNNEL=youruser@your-local-machine.com
SSH_RESTART=yes
```

**For paper trading, change:**
```bash
TRADING_MODE=paper
```

**Secure the file:**
```bash
chmod 600 .env
```

### 6. Optional: Configure Persistent Settings

If you want IB Gateway settings to persist across container restarts:

**Edit docker-compose.yml:**
```bash
cd ~/ib-gateway
vim docker-compose.yml
```

**Uncomment the volumes section:**
```yaml
    volumes:
      # Persistent IB Gateway settings
      - ${PWD}/tws_settings/:${TWS_SETTINGS_PATH:-/home/ibgateway/Jts}
      # SSH keys for tunnel authentication
      - ${PWD}/ssh/:/home/ibgateway/.ssh
```

**Create the directory:**
```bash
mkdir -p ~/ib-gateway/tws_settings
```

## Deployment

### 7. Deploy Container

```bash
cd ~/ib-gateway

# Pull the image
docker compose pull

# Start container
docker compose up -d

# Monitor logs
docker compose logs -f
```

### 8. Monitor Startup

Watch for these in logs:
- [ ] `✓ Starting Xvfb...`
- [ ] `✓ Starting IBC...`
- [ ] `✓ Gateway started successfully`
- [ ] `✓ SSH tunnel established` (if using)

### 9. Handle First Login

- [ ] Check logs for 2FA prompt
- [ ] Approve login via IBKR Mobile app
- [ ] Wait for "Gateway started successfully"

## Verification

### 10. Test API Connectivity

**On your local machine:**
```bash
# Test connection (for live trading on port 4001)
telnet localhost 4001

# Or use netcat
nc -zv localhost 4001

# For paper trading, use port 4002
nc -zv localhost 4002
```

### 11. Test with Trading App

```python
# Example with ib_insync
from ib_insync import IB

ib = IB()
ib.connect('localhost', 4001, clientId=1)  # 4001 for live, 4002 for paper
print(ib.accountValues())
ib.disconnect()
```

## Post-Deployment

### 12. Setup Monitoring

- [ ] Verify auto-restart: `docker compose ps` shows "restart: always"
- [ ] Check resource usage: `docker stats ib-gateway`
- [ ] Setup log rotation if needed

### 13. Backup Configuration

```bash
cd ~/ib-gateway
tar -czf ib-gateway-backup-$(date +%Y%m%d).tar.gz .env ssh/
```

### 14. Document Your Setup

- [ ] Note your VPS IP address
- [ ] Note your timezone setting
- [ ] Note your auto-restart time
- [ ] Save backup of .env file (securely!)

## Common Issues

**Container won't start:**
```bash
docker compose logs
docker compose down
docker compose pull
docker compose up -d
```

**SSH tunnel not working:**
```bash
# Check SSH process in container
docker compose exec ib-gateway ps aux | grep ssh

# Test SSH from container
docker compose exec ib-gateway ssh -i /home/ibgateway/.ssh/ib_tunnel_key youruser@your-local-machine.com echo "test"
```

**Authentication failures:**
- Verify credentials in .env
- Check for special characters that need escaping
- Approve new login location via IBKR Mobile

**API connection refused:**
```bash
# Restart socat (port forwarder)
docker compose exec ib-gateway pkill socat
# Will auto-restart
```

## Maintenance

**Update to new version:**
```bash
cd ~/ib-gateway
docker compose pull
docker compose down
docker compose up -d
```

**View logs:**
```bash
docker compose logs -f --tail=100
```

**Restart container:**
```bash
docker compose restart
```

## Security Checklist

- [ ] .env file has chmod 600 permissions
- [ ] UFW firewall is enabled on VPS
- [ ] API ports bound to 127.0.0.1 only (not exposed to internet)
- [ ] SSH keys have proper permissions (chmod 600)
- [ ] Using SSH tunnel for remote access (not direct port exposure)
- [ ] VNC disabled in production (VNC_SERVER_PASSWORD empty)
- [ ] Regular VPS system updates: `sudo apt update && sudo apt upgrade`

## Resources

- **Full Documentation**: [VPS-DEPLOYMENT.md](./VPS-DEPLOYMENT.md)
- **GitHub Repository**: https://github.com/TOMO-Labs/ib-gateway
- **IB API Docs**: https://interactivebrokers.github.io/tws-api/
- **Docker Compose Docs**: https://docs.docker.com/compose/

## Quick Commands Reference

```bash
# Start
docker compose up -d

# Stop
docker compose down

# Restart
docker compose restart

# Logs (follow)
docker compose logs -f

# Logs (last 100 lines)
docker compose logs --tail=100

# Container status
docker compose ps

# Pull latest image
docker compose pull

# Update and restart
docker compose pull && docker compose up -d

# Shell into container
docker compose exec ib-gateway bash

# Check processes in container
docker compose exec ib-gateway ps aux

# Restart SSH tunnel
docker compose exec ib-gateway pkill ssh

# Restart socat (port forwarder)
docker compose exec ib-gateway pkill socat
```
