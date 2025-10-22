#!/bin/bash
# Check VPN setup status

Host *
  IdentityAgent "/Users/griezzly/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"


echo "==> Checking VPN Status"
echo ""

# Check worker side
WORKER_IP=$(cd ../terraform && terraform output -json worker_public_ipv4s | jq -r '.[0]')
echo "Worker: $WORKER_IP"
echo ""

echo "Worker WireGuard status:"
ssh root@"$WORKER_IP" "wg show wg0" || echo "  Not configured"
echo ""

# Check Mac side
echo "Mac WireGuard status:"
if sudo wg show wg-oakestra 2>/dev/null; then
    echo "  ✅ VPN is running!"
    echo ""
    echo "Testing connectivity to service IPs:"
    ping -c 2 10.30.10.11 2>&1 | grep -E "transmitted|loss"
else
    echo "  ❌ VPN not running"
    echo ""
    echo "To start VPN, run:"
    echo "  sudo wg-quick up wg-oakestra"
fi