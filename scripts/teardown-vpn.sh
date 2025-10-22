#!/bin/bash
# Teardown WireGuard VPN access to Oakestra
# This script removes the VPN configuration from your Mac
#
# Usage: sudo ./teardown-vpn.sh

set -e

WG_CONFIG_PATH="/usr/local/etc/wireguard/wg-oakestra.conf"
WG_INTERFACE="wg-oakestra"

echo "==> Oakestra VPN Teardown"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run with sudo"
    echo "Usage: sudo $0"
    exit 1
fi

# Stop WireGuard interface if running
echo "==> Stopping WireGuard interface..."
# Try wg-quick down first
if wg-quick down "$WG_INTERFACE" 2>/dev/null; then
    echo "✅ WireGuard interface stopped via wg-quick"
# If that fails, try looking for the utun interface directly
elif ifconfig | grep -q "utun.*172.16.0.2"; then
    echo "Found WireGuard interface, attempting manual cleanup..."
    # Get the interface name
    UTUN_INTERFACE=$(ifconfig | grep -B 1 "172.16.0.2" | head -1 | awk '{print $1}' | tr -d ':')
    if [ -n "$UTUN_INTERFACE" ]; then
        echo "Removing interface: $UTUN_INTERFACE"
        ifconfig "$UTUN_INTERFACE" down 2>/dev/null || true
        echo "✅ WireGuard interface stopped manually"
    fi
else
    echo "ℹ️  WireGuard interface not running"
fi

# Remove configuration file
echo "==> Removing WireGuard configuration..."
if [ -f "$WG_CONFIG_PATH" ]; then
    rm -f "$WG_CONFIG_PATH"
    echo "✅ Configuration file removed: $WG_CONFIG_PATH"
else
    echo "ℹ️  Configuration file not found"
fi

# Clean up any leftover routes (in case interface didn't clean up properly)
echo "==> Cleaning up routes..."
SERVICE_ROUTE_EXISTS=$(netstat -rn | grep -c "10.30" || true)
PRIVATE_ROUTE_EXISTS=$(netstat -rn | grep -c "10.0" || true)

if [ "$SERVICE_ROUTE_EXISTS" -gt 0 ]; then
    route delete -net 10.30.0.0/16 2>/dev/null || true
    echo "✅ Route 10.30.0.0/16 removed"
fi

if [ "$PRIVATE_ROUTE_EXISTS" -gt 0 ]; then
    route delete -net 10.0.0.0/16 2>/dev/null || true
    echo "✅ Route 10.0.0.0/16 removed"
fi

if [ "$SERVICE_ROUTE_EXISTS" -eq 0 ] && [ "$PRIVATE_ROUTE_EXISTS" -eq 0 ]; then
    echo "ℹ️  No routes to clean up"
fi

# Check for leftover utun interfaces (shouldn't happen, but just in case)
UTUN_COUNT=$(ifconfig | grep -c "utun.*172.16.0.2" || true)
if [ "$UTUN_COUNT" -gt 0 ]; then
    echo "⚠️  Warning: Found leftover WireGuard interface(s)"
    echo "   This should be cleaned up automatically on next reboot"
fi

echo ""
echo "=========================================="
echo "✅ VPN Teardown Complete!"
echo "=========================================="
echo ""
echo "The Oakestra VPN has been removed from your Mac."
echo ""
echo "To set it up again, run:"
echo "  cd /Users/griezzly/workspace/acorn/scripts"
echo "  sudo ./setup-vpn-access.sh"
echo ""