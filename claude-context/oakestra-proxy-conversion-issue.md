# Oakestra Service IP Proxy Conversion Issue

## Issue Summary

**Service IP to Container IP proxy conversion shows asymmetric behavior: the nginx service (10.30.55.55) is properly registered and accessible cluster-wide, while AcmeAir services (10.30.10.x) fail to register in the translation table, preventing inbound connections to those services.**

## Environment

- **Oakestra Setup**: 2-node cluster (orchestrator + worker)
- **Orchestrator**: 116.203.149.6 (Public), 10.0.0.3 (Private)
- **Worker Node**: 167.235.134.239 (Public), 10.0.0.2 (Private)
- **Services Running**: NetManager, NodeEngine (both active and functional)
- **Application**: AcmeAir multi-container application (MongoDB + AuthService + Main App)

## Expected Behavior (According to Documentation)

Based on Oakestra's [IPv4 addressing documentation](https://www.oakestra.io/docs/manuals/networking-internals/ipv4-addressing/) and [proxy conversion documentation](https://www.oakestra.io/docs/manuals/networking-internals/proxy-conversion/):

1. **Service IP Configuration**: Applications specify `rr_ip` addresses in SLA files (e.g., `10.30.10.11`)
2. **Automatic Translation**: NetManager should automatically translate service IPs to actual container IPs
3. **Transparent Connectivity**: Applications should be able to connect to service IPs as if they were real interfaces
4. **Two-Layer Architecture**: Service layer (10.30.x.x) should map to worker subnet layer (10.18.x.x)

### Reference Working Example
The [nginx-client-server example](https://www.oakestra.io/docs/manuals/app-catalog/nginx-client-server-with-load-balancing/) demonstrates this working correctly:
```json
{
  "cmd": ["sh", "-c", "curl 10.30.55.55 ; sleep 5"],
  "addresses": {"rr_ip": "10.30.55.55"}
}
```

## Actual Behavior (Current Issue)

### Service Configuration
```json
{
  "microservice_name": "mongodb",
  "addresses": {"rr_ip": "10.30.10.11"},
  "port": "27017:27017"
}
```

### Container Network Assignment
- **Configured Service IP**: `10.30.10.11`
- **Actual Container IP**: `10.18.0.66` (assigned by worker subnet)
- **Bridge Network**: `10.18.0.64/26` via `goProxyBridge`

### Application Connection Attempts
```
MongoError: connection 4 to 10.30.10.11:27017 timed out
Error connecting to database - exiting process
```

### Network Analysis Results

#### ✅ What Works
- **Container-to-Container Direct**: `10.18.0.68` → `10.18.0.66:27017` ✅ SUCCESS
- **Host-to-Service**: Host can reach `10.30.10.11:27017` (with manual fixes)
- **Basic Networking**: All Oakestra network components operational
- **Service Registration**: Oakestra API correctly shows `"rr_ip": "10.30.10.11"`

#### ❌ What Fails  
- **AcmeAir Service IPs**: All AcmeAir services (10.30.10.x) unreachable from any container
- **Service Registration**: AcmeAir services not registered in NetManager translation table
- **Inbound Proxy Conversion**: AcmeAir services cannot receive connections via service IPs

#### 🔍 **CRITICAL DISCOVERY: Asymmetric Proxy Conversion Behavior**

**Recent testing revealed that the proxy conversion mechanism IS functional, but behaves asymmetrically:**

| Source Container | Target Service | Service IP | Container IP | Result |
|-----------------|---------------|-------------|--------------|--------|
| AcmeAir App (10.18.0.68) | nginx | 10.30.55.55 | 10.18.0.69 | ✅ **SUCCESS** |
| AcmeAir App (10.18.0.68) | AcmeAir MongoDB | 10.30.10.11 | 10.18.0.66 | ❌ **FAILED** |
| AcmeAir App (10.18.0.68) | AcmeAir AuthService | 10.30.10.1 | 10.18.0.67 | ❌ **FAILED** |
| nginx (10.18.0.69) | AcmeAir App | 10.30.10.2 | 10.18.0.68 | ❌ **FAILED** |

**Key Insights:**
- ✅ **nginx service (10.30.55.55)**: Properly registered, accessible cluster-wide
- ❌ **AcmeAir services (10.30.10.x)**: Registration failed, unreachable via service IPs
- ✅ **All direct container IPs**: Working perfectly for inter-container communication

## Technical Analysis

### Network Infrastructure Status
```bash
# Overlay tunnel (working)
goProxyTun: 10.19.1.254/12

# Container bridge (working) 
goProxyBridge: 10.18.0.65/26

# Container assignments (working)
MongoDB: 10.18.0.66
AuthService: 10.18.0.67  
MainApp: 10.18.0.68
```

### Missing Proxy Conversion Components

1. **No Service IP Interfaces**: 10.30.x.x addresses not configured on any interface
2. **No Routing**: No routes to 10.30.x.x network from container namespaces
3. **No DNAT Rules**: No automatic iptables rules for service IP translation
4. **No Dynamic Management**: NetManager not creating/managing proxy conversion rules

### Manual Fix Attempt Results

Applied manual proxy conversion simulation:
```bash
# Added service IPs to bridge
ip addr add 10.30.10.11/32 dev goProxyBridge

# Added routing  
ip route add 10.30.10.0/24 dev goProxyBridge

# Added DNAT rules
iptables -t nat -A OAKESTRA -p tcp --dport 27017 -d 10.30.10.11 -j DNAT --to-destination 10.18.0.66:27017
```

**Results**:
- ✅ Service IPs become routable from containers
- ✅ DNAT rules triggered (confirmed via packet counters)
- ✅ Traffic reaches target containers (confirmed via tcpdump)
- ❌ Application connections still fail (connection state issues)

### Traffic Analysis (tcpdump)
```
# Container sends to service IP
10.18.0.68.32806 > 10.30.10.11.27017: [SYN]

# DNAT translates to container IP  
10.18.0.68.32806 > 10.18.0.66.27017: [SYN]

# MongoDB responds
10.18.0.66.27017 > 10.18.0.68.32806: [SYN,ACK]

# But connection still fails at application layer
```

## Root Cause Analysis

### **Updated Primary Issue (Based on New Evidence)**
**Selective Service Registration Failure**: The NetManager proxy conversion mechanism IS functional, but AcmeAir services fail to register in the translation table while nginx services register successfully. This indicates a problem in the service registration pipeline, not the proxy conversion system itself.

**Evidence Supporting This Conclusion:**
1. ✅ **Proxy Conversion Works**: AcmeAir containers can successfully connect to nginx service IP (10.30.55.55)
2. ✅ **NetManager Functional**: Translation table correctly resolves nginx service to container IP
3. ❌ **AcmeAir Registration Failed**: AcmeAir services (10.30.10.x) not found in translation table
4. ✅ **Container Networking Intact**: All direct IP communication works perfectly

### **Refined Root Cause**
**MQTT-based service registration is failing selectively for AcmeAir services**. Based on NetManager source code analysis:

1. **Service Registration Flow**: NodeEngine → Cluster Manager → MQTT Distribution → NetManager Translation Table
2. **nginx Success**: Service registration completes, translation table populated, proxy conversion works
3. **AcmeAir Failure**: Service registration fails or is lost, translation table empty, proxy conversion unavailable

### Secondary Issues
1. **Registration Timing**: Possible race condition between service deployment and registration
2. **MQTT Communication**: Potential issues in cluster manager MQTT distribution for specific service IP ranges
3. **NodeEngine Integration**: Service registration may fail during container lifecycle events

## Impact Assessment

### Application Impact
- **Complete Service Failure**: Multi-container applications cannot communicate via service IPs
- **Workaround Required**: Must use direct container IPs, breaking service abstraction
- **Scalability Issues**: Direct IP usage prevents load balancing and service discovery

### Development Impact  
- **Deployment Complexity**: Requires manual IP management instead of service-based configuration
- **Testing Difficulties**: Cannot test applications as designed
- **Documentation Mismatch**: Documented features don't work as described

## Comparison with Working Example

### nginx-client-server (✅ Works)
- **Configuration**: Uses service IP `10.30.55.55`
- **Container IP**: `10.18.0.69`
- **Registration Status**: ✅ Successfully registered in NetManager translation table
- **Accessibility**: ✅ Accessible from any container cluster-wide via service IP
- **MQTT Distribution**: ✅ Service registration propagated correctly

### AcmeAir Application (❌ Fails)
- **Configuration**: Uses service IPs `10.30.10.1`, `10.30.10.2`, `10.30.10.11`
- **Container IPs**: `10.18.0.67`, `10.18.0.68`, `10.18.0.66`
- **Registration Status**: ❌ Not found in NetManager translation table
- **Accessibility**: ❌ Unreachable via service IPs, only direct IPs work
- **MQTT Distribution**: ❌ Service registration failed or lost

### **Critical Difference Identified**
The fundamental difference is **service registration success vs failure**, not configuration or networking infrastructure. Both applications use identical SLA patterns and deploy to the same network infrastructure, but only nginx successfully registers with the NetManager translation service.

## Reproduction Steps

1. **Deploy Multi-Container Application**:
   ```bash
   curl -X POST "http://116.203.149.6:10000/api/application/" \
     -H "Authorization: Bearer $TOKEN" \
     -d @acmeair.json
   ```

2. **Verify Service IP Configuration**:
   ```bash
   curl -H "Authorization: Bearer $TOKEN" \
     "http://116.203.149.6:10000/api/service/$SERVICE_ID" | jq .addresses
   # Shows: {"rr_ip": "10.30.10.11"}
   ```

3. **Check Container Network Assignment**:
   ```bash
   ctr -n oakestra task exec --exec-id test $CONTAINER cat /proc/net/fib_trie
   # Shows: 10.18.0.66 (actual IP differs from configured service IP)
   ```

4. **Test Service IP Connectivity**:
   ```bash
   ctr -n oakestra task exec --exec-id test $CONTAINER \
     timeout 3 bash -c "</dev/tcp/10.30.10.11/27017"
   # Result: Connection timeout
   ```

5. **Test Direct IP Connectivity**:
   ```bash
   ctr -n oakestra task exec --exec-id test $CONTAINER \
     timeout 3 bash -c "</dev/tcp/10.18.0.66/27017"  
   # Result: Connection success
   ```

6. **Test Cross-Application Service IP Access** (Demonstrates Asymmetric Behavior):
   ```bash
   # From AcmeAir to nginx service IP (Should work)
   ctr -n oakestra task exec --exec-id test acmeair.acmeair.acmeair.acmeair.instance.0 \
     timeout 3 bash -c "</dev/tcp/10.30.55.55/80"
   # Result: Connection success ✅
   
   # From nginx to AcmeAir service IP (Should fail) 
   ctr -n oakestra task exec --exec-id test clientsrvr.test.nginx.test.instance.0 \
     timeout 3 bash -c "</dev/tcp/10.30.10.2/9080"
   # Result: Connection timeout ❌
   ```

## Workaround

### Temporary Solution
Use direct container IPs instead of service IPs in application configuration:

```json
{
  "environment": [
    "MONGO_URL=mongodb://10.18.0.66:27017/acmeair",
    "AUTH_SERVICE=10.18.0.67:9443"
  ]
}
```

### Limitations of Workaround
- **Breaks Service Abstraction**: Applications tied to specific container IPs
- **No Load Balancing**: Cannot distribute traffic across multiple instances
- **Manual IP Management**: Requires knowing allocated container IPs in advance
- **Scalability Issues**: Difficult to scale or reschedule containers

## Expected Fix

### Required Implementation
1. **Automatic Service IP Interface Creation**: NetManager should add service IPs to appropriate interfaces
2. **Dynamic DNAT Rule Management**: Automatic creation/removal of iptables rules for service translation
3. **Connection State Handling**: Proper netfilter connection tracking for bidirectional translation
4. **Service Registration Protocol**: Clear mechanism for services to register with NetManager

### Verification Criteria
After fix, the following should work:
```bash
# From any container, service IPs should be reachable
ctr -n oakestra task exec --exec-id test $CONTAINER \
  timeout 3 bash -c "</dev/tcp/10.30.10.11/27017"
# Expected: Connection success

# Application logs should show successful connections
NodeEngine logs | grep -v "connection.*timed out"
# Expected: No timeout errors
```

## Additional Context

### Service Configuration (acmeair.json)
```json
{
  "sla_version": "v2.0",
  "customerID": "Admin", 
  "applications": [{
    "application_name": "acmeair",
    "microservices": [
      {
        "microservice_name": "mongodb",
        "addresses": {"rr_ip": "10.30.10.11"},
        "port": "27017:27017",
        "code": "docker.io/library/mongo:4"
      },
      {
        "microservice_name": "authservice", 
        "addresses": {"rr_ip": "10.30.10.1"},
        "port": "9443:9443",
        "environment": ["MONGO_URL=mongodb://10.30.10.11:27017/acmeair"]
      },
      {
        "microservice_name": "acmeair",
        "addresses": {"rr_ip": "10.30.10.2"}, 
        "port": "9080:9080",
        "environment": [
          "AUTH_SERVICE=10.30.10.1:9443",
          "MONGO_URL=mongodb://10.30.10.11:27017/acmeair"
        ]
      }
    ]
  }]
}
```

### System Information
```bash
# Oakestra service status
● netmanager.service - active (running)  
● nodeengine.service - active (running)

# Network configuration
goProxyTun: 10.19.1.254/12 (overlay)
goProxyBridge: 10.18.0.65/26 (containers)
Allocated subnet: 10.18.0.64/26
```

## Priority

**High** - This is a fundamental networking feature that prevents multi-container applications from working as designed. The proxy conversion mechanism is essential for service discovery and load balancing in Oakestra deployments.

## Labels

- `networking`
- `proxy-conversion` 
- `service-discovery`
- `bug`
- `high-priority`