#!/bin/bash
# Unified script to setup WireGuard VPN access to Oakestra service IPs
# This script runs on your Mac and automatically configures the first worker node
#
# Prerequisites:
# - Terraform already applied in ../terraform/ with WireGuard firewall rule
# - SSH access to worker nodes
# - WireGuard installed on Mac (will install if missing)
#
# Usage: ./setup-vpn-access.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
WG_CONFIG_PATH="/usr/local/etc/wireguard/wg-oakestra.conf"

echo "==> Oakestra VPN Access Setup"
echo ""

# Check Terraform directory exists
if [ ! -d "$TERRAFORM_DIR" ]; then
    echo "❌ Error: Terraform directory not found at $TERRAFORM_DIR"
    exit 1
fi

# Get first worker IP from Terraform
cd "$TERRAFORM_DIR"
echo "==> Getting first worker IP from Terraform..."
WORKER_IP=$(terraform output -json worker_public_ipv4s | jq -r '.[0]')

if [ -z "$WORKER_IP" ] || [ "$WORKER_IP" == "null" ]; then
    echo "❌ Error: Could not get worker IP from Terraform"
    echo "Make sure 'terraform apply' has been run successfully"
    exit 1
fi

WORKER_NAME=$(terraform output -json worker_names | jq -r '.[0]')
echo "✅ Using worker: $WORKER_NAME ($WORKER_IP)"
echo ""

# Install WireGuard on Mac if needed
echo "==> Checking WireGuard installation..."
if ! command -v wg &> /dev/null; then
    echo "Installing WireGuard via Homebrew..."
    brew install wireguard-tools
else
    echo "✅ WireGuard already installed"
fi
echo ""

# Generate Mac WireGuard keys
echo "==> Generating WireGuard keys for Mac..."
MAC_PRIVATE_KEY=$(wg genkey)
MAC_PUBLIC_KEY=$(echo "$MAC_PRIVATE_KEY" | wg pubkey)
echo "✅ Mac keys generated"
echo ""

# Create temporary worker setup script
WORKER_SCRIPT=$(cat <<'EOF'
#!/bin/bash
set -e

MAC_PUBLIC_KEY="$1"

echo "==> Installing WireGuard on worker..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard >/dev/null 2>&1

echo "==> Generating worker WireGuard keys..."
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

echo "==> Creating WireGuard configuration..."
cat > /etc/wireguard/wg0.conf <<WGCONF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 172.16.0.1/30
ListenPort = 51820

# Selective forwarding for Oakestra service IPs and Hetzner private network
# This doesn't interfere with NetManager's goProxyTun (10.19.x.x)
PostUp = iptables -I FORWARD -i wg0 -d 10.30.0.0/16 -j ACCEPT
PostUp = iptables -I FORWARD -o wg0 -s 10.30.0.0/16 -j ACCEPT
PostUp = iptables -I FORWARD -i wg0 -d 10.0.0.0/16 -j ACCEPT
PostUp = iptables -I FORWARD -o wg0 -s 10.0.0.0/16 -j ACCEPT
# MASQUERADE traffic from VPN to private network so responses can return
PostUp = iptables -t nat -I POSTROUTING -s 172.16.0.0/30 -d 10.0.0.0/16 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -d 10.30.0.0/16 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -s 10.30.0.0/16 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -d 10.0.0.0/16 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -s 10.0.0.0/16 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 172.16.0.0/30 -d 10.0.0.0/16 -j MASQUERADE

[Peer]
PublicKey = $MAC_PUBLIC_KEY
AllowedIPs = 172.16.0.2/32
WGCONF

echo "==> Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# Stop existing instance if running
systemctl stop wg-quick@wg0 2>/dev/null || true

echo "==> Starting WireGuard..."
systemctl enable wg-quick@wg0 >/dev/null 2>&1
systemctl start wg-quick@wg0

echo "==> Worker setup complete!"
echo "WORKER_PUBLIC_KEY=$PUBLIC_KEY"
EOF
)

# Execute setup on worker
echo "==> Configuring WireGuard on worker node..."
echo "    (This may take 30-60 seconds for package installation)"
WORKER_OUTPUT=$(ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "bash -s -- '$MAC_PUBLIC_KEY'" <<< "$WORKER_SCRIPT")

# Extract worker public key from output
# Note: Using cut with -f2- to preserve all = signs (including trailing padding)
WORKER_PUBLIC_KEY=$(echo "$WORKER_OUTPUT" | grep "WORKER_PUBLIC_KEY=" | cut -d'=' -f2-)

if [ -z "$WORKER_PUBLIC_KEY" ]; then
    echo "❌ Error: Could not get worker public key"
    echo "Worker output:"
    echo "$WORKER_OUTPUT"
    exit 1
fi

echo "✅ Worker configured successfully"
echo ""

# Stop existing VPN if running
echo "==> Checking for existing WireGuard connection..."
if sudo wg-quick down wg-oakestra 2>/dev/null; then
    echo "✅ Stopped existing WireGuard connection"
elif ifconfig | grep -q "utun.*172.16.0.2"; then
    echo "Found existing interface, cleaning up..."
    UTUN_INTERFACE=$(ifconfig | grep -B 1 "172.16.0.2" | head -1 | awk '{print $1}' | tr -d ':')
    if [ -n "$UTUN_INTERFACE" ]; then
        sudo ifconfig "$UTUN_INTERFACE" down 2>/dev/null || true
        sudo route delete -net 10.30.0.0/16 2>/dev/null || true
        sudo route delete -net 10.0.0.0/16 2>/dev/null || true
        echo "✅ Cleaned up existing interface: $UTUN_INTERFACE"
    fi
else
    echo "ℹ️  No existing connection found"
fi

# Create Mac WireGuard config
echo "==> Creating WireGuard configuration on Mac..."
sudo mkdir -p "$(dirname "$WG_CONFIG_PATH")"

# Remove old config if exists
sudo rm -f "$WG_CONFIG_PATH"

# Create new config
sudo tee "$WG_CONFIG_PATH" > /dev/null <<MACCONF
[Interface]
PrivateKey = $MAC_PRIVATE_KEY
Address = 172.16.0.2/30

# Route Oakestra service IPs and Hetzner private network through VPN
# NetManager will handle service IP -> container IP translation
PostUp = route add -net 10.30.0.0/16 172.16.0.1
PostUp = route add -net 10.0.0.0/16 172.16.0.1
PostDown = route delete -net 10.30.0.0/16 172.16.0.1
PostDown = route delete -net 10.0.0.0/16 172.16.0.1

[Peer]
PublicKey = $WORKER_PUBLIC_KEY
Endpoint = $WORKER_IP:51820
AllowedIPs = 10.30.0.0/16, 10.0.0.0/16
PersistentKeepalive = 25
MACCONF

echo "✅ Mac configuration created at $WG_CONFIG_PATH"
echo ""

# Start WireGuard
echo "==> Starting WireGuard VPN..."
if sudo wg show wg-oakestra &>/dev/null; then
    echo "Stopping existing WireGuard connection..."
    sudo wg-quick down wg-oakestra 2>/dev/null || true
fi

sudo wg-quick up wg-oakestra

echo ""
echo "=========================================="
echo "✅ VPN Setup Complete!"
echo "=========================================="
echo ""
echo "Connected to: $WORKER_NAME ($WORKER_IP)"
echo "Accessible networks:"
echo "  - Oakestra services: 10.30.0.0/16"
echo "  - Hetzner private:   10.0.0.0/16"
echo ""
echo "Test connectivity:"
echo "  ping 10.0.1.10          # Orchestrator private IP"
echo "  ping 10.30.10.11        # Service IP"
echo ""
echo "Access Oakestra dashboard:"
echo "  http://10.0.1.10:80     # Via private network"
echo ""
echo "Example service connections:"
echo "  mongo mongodb://10.30.10.11:27017/acmeair"
echo "  curl http://10.30.10.2:9080/"
echo ""
echo "Check VPN status:"
echo "  sudo wg show wg-oakestra"
echo ""
echo "Stop VPN:"
echo "  sudo wg-quick down wg-oakestra"
echo ""
echo "Restart VPN:"
echo "  sudo wg-quick up wg-oakestra"
echo ""