#!/bin/bash
# IB Gateway VPS Setup Script
# This script automates the infrastructure setup on a fresh VPS
# Usage: bash vps-setup.sh

set -e  # Exit on any error

echo "=========================================="
echo "IB Gateway VPS Setup Script"
echo "=========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}ERROR: Please run this script as a regular user with sudo privileges, not as root.${NC}"
    exit 1
fi

# Check if sudo is available
if ! command -v sudo &> /dev/null; then
    echo -e "${RED}ERROR: sudo is not installed. Please install sudo first.${NC}"
    exit 1
fi

echo -e "${YELLOW}This script will:${NC}"
echo "  1. Update system packages"
echo "  2. Install Docker and Docker Compose"
echo "  3. Configure firewall (UFW)"
echo "  4. Create directory structure"
echo "  5. Generate SSH keys for tunnel"
echo "  6. Download docker-compose.yml and .env.example"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 0
fi

# Step 1: Update system packages
echo ""
echo -e "${GREEN}[1/6] Updating system packages...${NC}"
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl git vim ufw

# Step 2: Install Docker
echo ""
echo -e "${GREEN}[2/6] Installing Docker and Docker Compose...${NC}"

if command -v docker &> /dev/null; then
    echo "Docker is already installed ($(docker --version))"
else
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh

    # Add current user to docker group
    sudo usermod -aG docker $USER
    echo -e "${YELLOW}NOTE: You'll need to log out and back in for docker group changes to take effect${NC}"
fi

# Install docker-compose plugin
if command -v docker compose version &> /dev/null; then
    echo "Docker Compose is already installed ($(docker compose version))"
else
    echo "Installing Docker Compose plugin..."
    sudo apt install -y docker-compose-plugin
fi

# Step 3: Configure firewall
echo ""
echo -e "${GREEN}[3/6] Configuring firewall (UFW)...${NC}"

if sudo ufw status | grep -q "Status: active"; then
    echo "UFW is already active"
else
    echo "Configuring UFW..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    echo "y" | sudo ufw enable
    echo -e "${GREEN}Firewall configured and enabled${NC}"
fi

sudo ufw status

# Step 4: Create directory structure
echo ""
echo -e "${GREEN}[4/6] Creating directory structure...${NC}"

APP_DIR="$HOME/ib-gateway"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

mkdir -p ssh logs settings/live settings/paper
chmod 700 ssh
chmod 755 logs settings

echo "Directory structure created at: $APP_DIR"
ls -la

# Step 5: Generate SSH keys
echo ""
echo -e "${GREEN}[5/6] Generating SSH keys for tunnel authentication...${NC}"

if [ -f "$APP_DIR/ssh/ib_tunnel_key" ]; then
    echo "SSH key already exists at $APP_DIR/ssh/ib_tunnel_key"
    read -p "Overwrite? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$APP_DIR/ssh/ib_tunnel_key" "$APP_DIR/ssh/ib_tunnel_key.pub"
    fi
fi

if [ ! -f "$APP_DIR/ssh/ib_tunnel_key" ]; then
    ssh-keygen -t ed25519 -f "$APP_DIR/ssh/ib_tunnel_key" -N "" -C "ib-gateway@$(hostname)"
    echo -e "${GREEN}SSH keypair generated${NC}"
fi

echo ""
echo -e "${YELLOW}=========================================="
echo "IMPORTANT: SSH PUBLIC KEY"
echo "==========================================${NC}"
echo ""
echo "Add this public key to your local machine's ~/.ssh/authorized_keys:"
echo ""
cat "$APP_DIR/ssh/ib_tunnel_key.pub"
echo ""
echo -e "${YELLOW}==========================================${NC}"
echo ""

# Step 6: Download docker-compose.yml and .env.example
echo ""
echo -e "${GREEN}[6/6] Downloading configuration files...${NC}"

cd "$APP_DIR"

if [ -f "docker-compose.yml" ]; then
    echo "docker-compose.yml already exists"
    read -p "Overwrite? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "docker-compose.yml"
    fi
fi

if [ ! -f "docker-compose.yml" ]; then
    echo "Downloading docker-compose.yml..."
    curl -fsSL https://raw.githubusercontent.com/TOMO-Labs/ib-gateway/master/docker-compose.yml -o docker-compose.yml
    echo -e "${GREEN}docker-compose.yml downloaded${NC}"
fi

if [ -f ".env.example" ]; then
    echo ".env.example already exists"
else
    echo "Downloading .env.example..."
    curl -fsSL https://raw.githubusercontent.com/TOMO-Labs/ib-gateway/master/.env.example -o .env.example
    echo -e "${GREEN}.env.example downloaded${NC}"
fi

if [ ! -f ".env" ]; then
    echo "Creating .env from example..."
    cp .env.example .env
    chmod 600 .env
    echo -e "${GREEN}.env file created${NC}"
fi

# Final summary
echo ""
echo -e "${GREEN}=========================================="
echo "✅ VPS Setup Complete!"
echo "==========================================${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. ${YELLOW}Configure SSH tunnel on your local machine:${NC}"
echo "   Add the public key shown above to your local ~/.ssh/authorized_keys"
echo ""
echo "2. ${YELLOW}Edit .env file with your credentials:${NC}"
echo "   cd $APP_DIR"
echo "   vim .env"
echo "   (Set TWS_USERID, TWS_PASSWORD, SSH_USER_TUNNEL, etc.)"
echo ""
echo "3. ${YELLOW}Test SSH connection from VPS:${NC}"
echo "   ssh -i $APP_DIR/ssh/ib_tunnel_key youruser@your-local-machine.com echo 'Connection successful'"
echo ""
echo "4. ${YELLOW}Pull and start the container:${NC}"
echo "   cd $APP_DIR"
echo "   docker compose pull"
echo "   docker compose up -d"
echo ""
echo "5. ${YELLOW}Monitor logs:${NC}"
echo "   docker compose logs -f"
echo ""

if ! groups | grep -q docker; then
    echo -e "${YELLOW}⚠️  IMPORTANT: Log out and back in for docker group changes to take effect!${NC}"
    echo ""
fi

echo "For detailed documentation, see:"
echo "  https://github.com/TOMO-Labs/ib-gateway/blob/master/docs/VPS-DEPLOYMENT.md"
echo ""
echo -e "${GREEN}Setup complete!${NC}"
