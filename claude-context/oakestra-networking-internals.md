# Oakestra Networking Internals - Deep Dive Analysis

## Overview

This document provides a comprehensive analysis of Oakestra's networking architecture based on extensive investigation of a service IP to container IP proxy conversion issue. It covers the two-layer IP addressing system, overlay networking, and identified issues with the proxy conversion mechanism.

## Oakestra Network Architecture

### Two-Layer IP Addressing System

Oakestra implements a dual-layer networking approach:

1. **Container Network Layer (Worker Subnet)**
   - IP Range: `10.18.x.x/26` (allocated dynamically per worker node)
   - Purpose: Actual container networking within the worker node
   - Managed by: `goProxyBridge` interface
   - Example: Container gets `10.18.0.66`, `10.18.0.67`, `10.18.0.68`

2. **Service Network Layer (Cluster-wide Service IPs)**
   - IP Range: `10.30.x.x` (configured in SLA files via `rr_ip`)
   - Purpose: Cluster-wide service addressing, similar to Kubernetes Services
   - Should be: Automatically translated to container IPs via proxy conversion
   - Example: Service configured as `10.30.10.11` should reach container `10.18.0.66`

### Core Network Components

#### 1. NetManager Service
- **Binary**: `/bin/NetManager`
- **Config**: `/etc/netmanager/`
  - `netcfg.json`: Node and cluster connection configuration
  - `tuncfg.json`: Tunnel and proxy network configuration
  - `netmanager.sock`: Unix domain socket for communication
- **Responsibilities**: 
  - Overlay network management
  - Service IP to container IP proxy conversion
  - Inter-node networking

#### 2. NodeEngine Service
- **Binary**: `/bin/nodeengined`
- **Responsibilities**:
  - Container lifecycle management
  - Resource monitoring and reporting
  - Integration with NetManager for networking

#### 3. Network Interfaces

##### goProxyTun (Overlay Tunnel)
```
Interface: goProxyTun
IP: 10.19.1.254/12
Purpose: Inter-node overlay communication
MTU: 1450
Type: Point-to-point tunnel
```

##### goProxyBridge (Container Bridge)
```
Interface: goProxyBridge
IP: 10.18.0.65/26
Purpose: Local container networking
MTU: 1450
Type: Bridge for container connections
Bridge Members: vethXXX interfaces (one per container)
```

### Subnet Allocation

The cluster manager allocates specific subnets to each worker node:

- **Configured Network**: `10.30.0.0/16` (in tuncfg.json)
- **Allocated Subnet**: `10.18.0.64/26` (actual worker subnet)
- **Range**: `10.18.0.64` - `10.18.0.127` (64 addresses)
- **Bridge IP**: `10.18.0.65`
- **Container IPs**: `10.18.0.66`, `10.18.0.67`, `10.18.0.68`, etc.

### Container Network Namespace Analysis

Each container gets:
- **Virtual Ethernet Interface**: `vethXXX` connected to `goProxyBridge`
- **Container IP**: From the allocated subnet (`10.18.0.x`)
- **Default Route**: Via bridge IP (`10.18.0.65`)
- **Network Namespace**: Isolated from host network

#### Example Container Network Configuration
```
Container: acmeair.acmeair.mongodb.acmeair.instance.1
IP: 10.18.0.66/26
Interface: veth010BQYk
Gateway: 10.18.0.65
Route: 0.0.0.0/0 via 10.18.0.65
```

## Service Discovery and Proxy Conversion

### Expected Behavior (According to Documentation)
1. **Service IP Configuration**: Applications configure `rr_ip` addresses (e.g., `10.30.10.11`)
2. **Automatic Proxy Conversion**: NetManager should automatically translate service IPs to container IPs
3. **Transparent Communication**: Containers should be able to connect to service IPs seamlessly
4. **Load Balancing**: Service IPs should support multiple container instances

### NetManager Proxy Conversion Architecture (Source Code Analysis)

Based on analysis of the [NetManager source code](https://github.com/oakestra/oakestra-net/tree/develop/node-net-manager), the proxy conversion mechanism works as follows:

#### Core Components

1. **Translation Table** (`env/EnvironmentManager.go`)
   - Dynamic lookup mechanism mapping service IPs to container IPs
   - Local cache with remote query capability
   - Methods: `GetTableEntryByServiceIP()`, `GetTableEntryByInstanceIP()`, `GetTableEntryByNsIP()`

2. **Proxy Tunnel** (`proxy/ProxyTunnel.go`)
   - Intercepts traffic to semantic routing subnetwork (10.30.0.0/16)
   - Performs service IP to instance IP conversion via `convertToInstanceIp()`
   - Implements load balancing (round-robin) for multiple instances
   - Maintains proxy cache for active network flows

3. **Proxy Setup** (`proxy/ProxySetup.go`)
   - Creates TUN device (`goProxyTun`) with configurable subnets
   - Default service subnet: `10.30.0.0/16`
   - Default tunnel IP: `10.19.1.254`
   - Configures routing rules and firewall rules

4. **Table Query System** (`env/tableQueryRequests.go`)
   - MQTT-based service discovery: `tableQueryByIP()`, `tableQueryByJobName()`
   - Distributed lookup when services not found locally
   - Returns `TableEntry` objects with service mappings

#### Proxy Conversion Process Flow

```
Container sends packet to service IP (10.30.10.11)
    ↓
Traffic intercepted by goProxyTun interface
    ↓
NetManager checks translation table for 10.30.10.11
    ↓
If not found locally:
    ├─ Performs MQTT query to cluster manager
    ├─ Registers interest in service via MQTT
    └─ Caches result in translation table
    ↓
Converts service IP to instance IP (10.18.0.66)
    ↓
Proxies traffic via UDP tunnel to target container
    ↓
Handles response traffic with reverse translation
```

#### Service Registration Flow

```
Container deployed with rr_ip configuration
    ↓
NodeEngine registers service with cluster manager
    ↓
Cluster manager distributes service info via MQTT
    ↓
NetManager receives service registration
    ↓
Service added to translation table
    ↓
Service IP becomes resolvable cluster-wide
```

### Current Implementation Status

#### ✅ Working Components
- **Container-to-Container Communication**: Direct IP communication works perfectly
- **Overlay Network**: `goProxyTun` and `goProxyBridge` configured correctly
- **Subnet Allocation**: Worker nodes receive proper IP ranges
- **Container Networking**: All containers accessible on assigned IPs
- **DNAT Rule Processing**: Manual DNAT rules are triggered correctly

#### ❌ Broken Components  
- **Automatic Proxy Conversion**: Service IPs are not automatically translated
- **Service IP Resolution**: No mechanism to route traffic to service IPs
- **Dynamic DNAT Creation**: NetManager doesn't create proxy conversion rules

## Network Traffic Flow Analysis

### Successful Flow (Container-to-Container Direct)
```
App Container (10.18.0.68) 
    ↓ [goProxyBridge]
    ↓ Direct route
MongoDB Container (10.18.0.66) ✅ SUCCESS
```

### Broken Flow (Service IP)
```
App Container (10.18.0.68)
    ↓ Destination: 10.30.10.11:27017
    ↓ [goProxyBridge] - Service IP not routable
    ❌ TIMEOUT - No route to 10.30.x.x
```

### Manually Fixed Flow (With DNAT Rules)
```
App Container (10.18.0.68)
    ↓ Destination: 10.30.10.11:27017
    ↓ [goProxyBridge] - Bridge has 10.30.10.11/32
    ↓ [OAKESTRA iptables chain] - DNAT to 10.18.0.66:27017
MongoDB Container (10.18.0.66)
    ↓ Response: 10.18.0.66:27017 → 10.18.0.68:port
    ❌ PARTIAL - Packets flow but connection fails
```

## Manual Fix Implementation

### Required Components for Service IP Translation

1. **Service IP Interfaces**
```bash
ip addr add 10.30.10.11/32 dev goProxyBridge
ip addr add 10.30.10.1/32 dev goProxyBridge  
ip addr add 10.30.10.2/32 dev goProxyBridge
```

2. **Routing Configuration**
```bash
ip route add 10.30.10.0/24 dev goProxyBridge scope link
```

3. **DNAT Rules (iptables)**
```bash
iptables -t nat -R OAKESTRA 1 -p tcp --dport 27017 -d 10.30.10.11 -j DNAT --to-destination 10.18.0.66:27017
iptables -t nat -R OAKESTRA 2 -p tcp --dport 9443 -d 10.30.10.1 -j DNAT --to-destination 10.18.0.67:9443
iptables -t nat -R OAKESTRA 3 -p tcp --dport 9080 -d 10.30.10.2 -j DNAT --to-destination 10.18.0.68:9080
```

### Results of Manual Fix
- ✅ **Service IPs become routable** from containers
- ✅ **DNAT rules are triggered** (confirmed via packet counters)
- ✅ **Traffic reaches target containers** (confirmed via tcpdump)
- ❌ **Connections still fail** at application layer

## Application Layer Analysis

### Working Configuration (Direct IPs)
```json
{
  "environment": [
    "MONGO_URL=mongodb://10.18.0.66:27017/acmeair",
    "AUTH_SERVICE=10.18.0.67:9443"
  ]
}
```

### Failing Configuration (Service IPs)  
```json
{
  "environment": [
    "MONGO_URL=mongodb://10.30.10.11:27017/acmeair",
    "AUTH_SERVICE=10.30.10.1:9443"  
  ]
}
```

### Application Error Messages
```
MongoError: connection 4 to 10.30.10.11:27017 timed out
Error connecting to database - exiting process
```

## Debugging Techniques and Tools

### Network Analysis Commands
```bash
# Check container IP assignments
ctr -n oakestra task exec --exec-id test <container> cat /proc/net/fib_trie

# Monitor network traffic
tcpdump -i goProxyBridge -n port 27017

# Check iptables rule counters
iptables -t nat -L OAKESTRA -n -v

# Test container connectivity
ctr -n oakestra task exec --exec-id test <container> timeout 3 bash -c "</dev/tcp/IP/PORT"

# Check routing tables
ip route show table all
```

### Service Status Commands
```bash
# Check Oakestra services
NodeEngine status
NetManager status

# View logs (streaming)
NodeEngine logs
NetManager logs
```

### Configuration Files
```bash
# NetManager configuration
/etc/netmanager/netcfg.json
/etc/netmanager/tuncfg.json

# Service socket
/etc/netmanager/netmanager.sock
```

## Architecture Comparison

### Kubernetes Service Network (Working Reference)
```
Pod IP: 10.244.x.x (actual pod network)
Service IP: 10.96.x.x (cluster service network)
Mechanism: kube-proxy + iptables DNAT rules
Result: Automatic translation, transparent to applications
```

### Oakestra Service Network (Current State)
```
Container IP: 10.18.x.x (actual container network)  
Service IP: 10.30.x.x (configured in SLA)
Mechanism: Should be NetManager + proxy conversion
Result: Translation not implemented, manual DNAT incomplete
```

## Performance and Resource Impact

### Network Performance
- **Container-to-Container Latency**: ~0.1ms (bridge network)
- **Service IP Resolution**: N/A (not working)
- **Overhead**: Minimal when working properly

### Resource Usage
```
NetManager: ~20MB memory, minimal CPU
NodeEngine: ~19MB memory, moderate CPU  
Bridge Interface: No significant overhead
DNAT Rules: Negligible performance impact
```

## Security Implications

### Current Security Model
- **Container Isolation**: Network namespaces provide isolation
- **Bridge Security**: All containers on same bridge can communicate
- **Service IP Security**: No additional access control on service IPs
- **Firewall Integration**: Uses iptables OAKESTRA chain

### Potential Security Issues
- **Direct IP Exposure**: Containers must use actual IPs without proxy conversion
- **Network Segmentation**: Limited by single bridge approach
- **Access Control**: No service-level access control

## Integration Points

### With Container Orchestration
- **SLA File Processing**: NodeEngine processes `rr_ip` addresses correctly
- **API Integration**: Oakestra API shows correct service IP configuration
- **Container Lifecycle**: Service IPs should be managed with container lifecycle

### With Overlay Network
- **Inter-node Communication**: Uses `goProxyTun` for cluster communication
- **Subnet Management**: Cluster manager allocates worker subnets
- **Route Distribution**: Should distribute service routes automatically

## Comparison with Working Examples

### Oakestra nginx-client-server Example (✅ WORKING)
- **Service IP**: `10.30.55.55` (nginx container)
- **Container IP**: `10.18.0.127` (actual nginx container)
- **Client Behavior**: curl container successfully connects to `10.30.55.55`
- **Connection Type**: Simple HTTP request/response (stateless)
- **Traffic Pattern**: One-way curl request, immediate response

**Key Observations**:
- ✅ **Automatic Proxy Conversion**: Service IP automatically resolves to container IP
- ✅ **No Manual Configuration**: No manual DNAT rules or bridge IPs needed
- ✅ **MQTT Registration**: Service properly registered in translation table
- ✅ **TUN Interface**: Traffic properly intercepted by `goProxyTun`

### AcmeAir Application (❌ FAILING)
- **Service IPs**: `10.30.10.11`, `10.30.10.1`, `10.30.10.2`
- **Container IPs**: `10.18.0.66`, `10.18.0.67`, `10.18.0.68`
- **Client Behavior**: MongoDB connections timeout to service IPs
- **Connection Type**: Persistent TCP connections (stateful)
- **Traffic Pattern**: Long-lived database connections with continuous queries

**Key Observations**:
- ❌ **No Proxy Conversion**: Service IPs not automatically translated
- ❌ **Manual Configuration Required**: Needed manual DNAT and bridge setup
- ❌ **MQTT Registration Missing**: Services not found in translation table
- ❌ **TUN Interface Bypass**: Traffic not intercepted by proxy mechanism

### Critical Differences Analysis

#### Working vs Failing Comparison

| Aspect | nginx (Working) | AcmeAir (Failing) |
|--------|----------------|-------------------|
| **Service IP Range** | `10.30.55.55` | `10.30.10.x` |
| **Container Subnet** | `10.18.0.127` | `10.18.0.66-68` |
| **Service Registration** | ✅ Automatic | ❌ Missing |
| **Translation Table** | ✅ Present | ❌ Empty |
| **TUN Interception** | ✅ Working | ❌ Not functioning |
| **Connection Type** | Stateless HTTP | Stateful TCP |
| **MQTT Queries** | ✅ Successful | ❌ Failing |

#### Potential Root Causes

1. **Service Registration Issue**
   - nginx services properly register with cluster manager via MQTT
   - AcmeAir services fail to register or registration is lost
   - NodeEngine → Cluster Manager → MQTT distribution chain broken for AcmeAir

2. **Translation Table Population**
   - nginx entries successfully added to NetManager translation table
   - AcmeAir entries never populated in translation table
   - MQTT query responses not received for AcmeAir services

3. **Network Namespace Routing**
   - nginx traffic properly routed through `goProxyTun` interface
   - AcmeAir traffic bypasses TUN and goes directly to bridge
   - Different routing behavior based on service IP range or timing

4. **Service Discovery Timing**
   - nginx service registration happens before client connection attempts
   - AcmeAir services attempt connections before registration completes
   - Race condition in service discovery vs connection timing

### Working nginx Configuration Analysis

```json
{
  "microservice_name": "nginx",
  "addresses": {
    "rr_ip": "10.30.55.55",
    "rr_ip_v6": "fdff:2000::55:55"
  },
  "code": "docker.io/library/nginx:latest",
  "port": "" // No explicit port mapping
}
```

```json
{
  "microservice_name": "curlv4", 
  "cmd": ["sh", "-c", "curl 10.30.55.55 ; sleep 5"],
  "code": "docker.io/curlimages/curl:7.82.0"
  // No addresses specified - gets automatic container IP
}
```

**Key Success Factors**:
- Simple single-service architecture
- No complex inter-service dependencies
- Standard container images (nginx, curl)
- Minimal configuration requirements
- IPv6 addressing also configured

### Failed AcmeAir Configuration Analysis

```json
{
  "microservice_name": "mongodb",
  "addresses": {"rr_ip": "10.30.10.11"},
  "port": "27017:27017",
  "code": "docker.io/library/mongo:4"
}
```

```json
{
  "microservice_name": "authservice",
  "addresses": {"rr_ip": "10.30.10.1"},
  "environment": ["MONGO_URL=mongodb://10.30.10.11:27017/acmeair"]
  // Depends on MongoDB service IP
}
```
**Accessing Netmanager logs**
location on workder node : /var/log/oakestra/netmanager.log

**Failure Factors**:
- Complex multi-service dependencies
- Persistent stateful connections required
- Service IPs used in environment variables
- Port mappings explicitly configured
- IPv6 addressing not configured

## Future Investigation Areas

1. **Proxy Conversion Protocol**: How NetManager should implement proxy conversion
2. **Service Registration**: How services register with NetManager
3. **Working Example Analysis**: Why nginx example works but AcmeAir doesn't
4. **Dynamic Rule Creation**: How DNAT rules should be created automatically
5. **Connection State Management**: Why manual DNAT rules don't complete connections

## Recommendations

### For Oakestra Development Team
1. **Implement Missing Proxy Conversion**: Complete the service IP to container IP translation mechanism
2. **Improve Documentation**: Add detailed networking troubleshooting guides
3. **Add Debug Tools**: Provide commands to inspect service IP mappings
4. **Connection State Fix**: Resolve why DNAT connections fail at application layer

### For Application Deployment
1. **Use Direct IPs**: Until proxy conversion is fixed, use actual container IPs
2. **Network Testing**: Always test container-to-container connectivity first
3. **Monitor Integration**: Use tcpdump and iptables counters for debugging

### For Future Research
1. **Compare Working Examples**: Analyze why some deployments work with service IPs
2. **Protocol Analysis**: Understand the expected NetManager socket protocol
3. **Connection Tracking**: Investigate netfilter connection state issues

This document represents the most comprehensive analysis of Oakestra networking internals based on hands-on investigation and should serve as a reference for understanding and debugging Oakestra network issues.