# VPN Access to Oakestra Service IPs

This guide explains how to access Oakestra service IPs (`10.30.x.x`) from your Mac using WireGuard VPN.

## How It Works

```
Your Mac (172.16.0.2)
    ↓ WireGuard tunnel to worker-1
Worker Node (172.16.0.1)
    ↓ Request to service IP (e.g., 10.30.10.11)
NetManager on worker
    ↓ Translates service IP → container IP (e.g., 10.18.0.66)
    ↓ Routes via goProxyTun overlay network
Target container (on any worker in cluster)
```

**Key points:**
- VPN connects to **first worker node only**
- NetManager handles cluster-wide service discovery
- Service IPs work transparently just like for containers in the cluster
- No conflicts with NetManager's `goProxyTun` (`10.19.x.x`) overlay

## Prerequisites

1. **Terraform infrastructure deployed** with WireGuard firewall rule
2. **SSH access** to worker nodes (root)
3. **jq** installed on Mac: `brew install jq`

## Setup Steps

### 1. Apply Terraform Changes

The firewall rule for WireGuard (port 51820/udp) has been added to `terraform/main.tf`.

```bash
cd terraform
terraform plan
terraform apply
```

### 2. Run the Setup Script

```bash
cd scripts
./setup-vpn-access.sh
```

The script will automatically:
- ✅ Get first worker IP from Terraform
- ✅ Install WireGuard on Mac (if needed)
- ✅ Generate WireGuard keys for both sides
- ✅ Configure worker node via SSH
- ✅ Create Mac WireGuard config
- ✅ Start the VPN connection

### 3. Test Connectivity

```bash
# Test basic connectivity
ping 10.30.10.11

# Connect to MongoDB service
mongo mongodb://10.30.10.11:27017/acmeair

# Test HTTP services
curl http://10.30.10.2:9080/
curl https://10.30.10.1:9443/health
```

## VPN Management

### Check VPN Status
```bash
sudo wg show wg-oakestra
```

### Stop VPN
```bash
sudo wg-quick down wg-oakestra
```

### Start VPN
```bash
sudo wg-quick up wg-oakestra
```

### Check Routes
```bash
netstat -rn | grep 10.30
```

## Configuration Files

- **Mac config**: `/usr/local/etc/wireguard/wg-oakestra.conf`
- **Worker config**: `/etc/wireguard/wg0.conf` (on worker-1)

## Network Details

### VPN Tunnel Network
- Mac: `172.16.0.2/30`
- Worker: `172.16.0.1/30`
- Port: `51820/udp`

### Routed Networks
- Service IPs: `10.30.0.0/16` (only)
- **Not routed**: `10.19.x.x` (NetManager overlay)
- **Not routed**: `10.18.x.x` (container IPs)

## Security Considerations

The firewall rule allows WireGuard connections from any source IP (`0.0.0.0/0`).

For production, you can restrict this to your specific IP:

```hcl
# In terraform/main.tf
rule {
  direction = "in"
  protocol  = "udp"
  port      = "51820"
  source_ips = [
    "YOUR.MAC.IP.ADDRESS/32"
  ]
}
```

## Troubleshooting

### VPN connects but can't reach services

1. **Check WireGuard handshake:**
   ```bash
   sudo wg show wg-oakestra
   # Look for "latest handshake: X seconds ago"
   ```

2. **Verify routing:**
   ```bash
   netstat -rn | grep 10.30
   # Should show: 10.30/16 -> 172.16.0.1
   ```

3. **Test from worker node:**
   ```bash
   ssh root@<worker-ip>
   ping 10.30.10.11  # Should work
   ```

4. **Check NetManager:**
   ```bash
   ssh root@<worker-ip>
   NetManager status
   NetManager logs
   ```

### Permission denied errors

Run with `sudo`:
```bash
sudo wg-quick up wg-oakestra
```

### Port already in use on worker

Stop existing WireGuard:
```bash
ssh root@<worker-ip>
systemctl stop wg-quick@wg0
```

Then re-run setup script.

## Advanced: Manual Setup

If you need to set up VPN on a different worker or customize the configuration, see:
- `setup-mac-wireguard.sh` - Mac-side manual setup
- `setup-worker-wireguard.sh` - Worker-side manual setup