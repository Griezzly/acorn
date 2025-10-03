# Oakestra Deployment Agent Context

This document provides comprehensive context for agents handling Oakestra orchestration platform deployments.

## Overview

Oakestra is an open-source edge computing orchestration platform. This context enables agents to:
- Deploy applications using SLA JSON files
- Manage application lifecycle (deploy, update, delete)
- Monitor deployment status
- Troubleshoot deployment issues
- Maintain state context across operations

## Context Management System

### Agent State Storage
Agents MUST maintain a persistent context log to track deployment state and operations:

```json
{
  "session_id": "unique-session-identifier",
  "timestamp": "2025-01-10T12:30:00Z",
  "oakestra_endpoint": "http://116.203.149.6:10000",
  "auth_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_expires": "2025-01-10T13:00:00Z",
  "current_user": "Admin",
  "current_organization": "6898713c1d87e075946067ba5",
  "deployed_applications": [
    {
      "application_name": "acmeair",
      "application_id": "6898768499b4b515b1189e68",
      "deployed_at": "2025-01-10T12:15:00Z",
      "status": "active",
      "microservices": [
        {
          "name": "mongodb",
          "service_id": "6898768499b4b515b1189e69",
          "ip": "10.30.10.11",
          "port": "27017"
        },
        {
          "name": "authservice", 
          "service_id": "6898768499b4b515b1189e6a",
          "ip": "10.30.10.1",
          "port": "9443"
        },
        {
          "name": "acmeair",
          "service_id": "6898768499b4b515b1189e6b", 
          "ip": "10.30.10.2",
          "port": "9080"
        }
      ]
    }
  ],
  "ip_allocations": [
    {"ip": "10.30.10.1", "allocated_to": "authservice", "app": "acmeair"},
    {"ip": "10.30.10.2", "allocated_to": "acmeair", "app": "acmeair"}, 
    {"ip": "10.30.10.11", "allocated_to": "mongodb", "app": "acmeair"}
  ],
  "recent_operations": [
    {
      "operation": "deploy_application",
      "target": "acmeair",
      "result": "success",
      "timestamp": "2025-01-10T12:15:00Z",
      "details": "Application deployed with 3 microservices"
    }
  ]
}
```

### Context Update Protocol
1. **Before any operation**: Check existing context for relevant state
2. **After successful operations**: Update context with new state information
3. **On errors**: Log error details but preserve existing valid state
4. **Token management**: Track token expiration and refresh automatically

## API Configuration

### Base Configuration
- **Platform**: Oakestra Edge Computing Orchestrator
- **Base URL**: `http://116.203.149.6:10000`
- **API Version**: REST API v1
- **Authentication**: JWT Bearer token
- **Content-Type**: `application/json`

### Authentication Credentials
- **Username**: `Admin` (case-sensitive)
- **Password**: `Admin` (case-sensitive)
- **Organization**: `default` (optional in request)

## Complete API Endpoints Reference

### 1. Authentication Endpoints

#### POST /api/auth/login
**Purpose**: User authentication and token acquisition

**Request Body**:
```json
{
  "username": "Admin",
  "password": "Admin",
  "organization": "default"
}
```

**Response** (200 OK):
```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refresh_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

**Behavioral Notes**:
- Token expires in 10 minutes (600 seconds)
- Username/password are case-sensitive
- Organization field is optional but recommended
- Store both access and refresh tokens

#### POST /api/auth/refresh
**Purpose**: Refresh expired access token

**Authentication**: Required (Bearer refresh token)

**Response** (200 OK):
```json
{
  "token": "new_access_token"
}
```

#### POST /api/auth/register  
**Purpose**: Register new user

**Request Body**:
```json
{
  "name": "string",
  "password": "string",
  "roles": ["string"]
}
```

### 2. Application Management Endpoints

#### POST /api/application/
**Purpose**: Deploy new application with microservices

**Authentication**: Required (Bearer token)

**Request Body**: Complete SLA JSON file

**Response** (200 OK):
```json
"[{\"applicationID\": \"6898768499b4b515b1189e68\", \"application_name\": \"acmeair\", \"microservices\": [\"service_id_1\", \"service_id_2\"]}]"
```

**Behavioral Notes**:
- Creates application and all microservices in single operation
- Returns application ID and microservice IDs
- Response is JSON string that needs parsing
- May return 409 Conflict if application already exists

#### GET /api/applications/
**Purpose**: List all applications for current user

**Authentication**: Required

**Response** (200 OK): Array of application objects

**Behavioral Notes**:
- Returns applications for authenticated user only
- Response format is JSON string requiring parsing

#### GET /api/application/{appid}
**Purpose**: Get specific application details

**Parameters**:
- `appid` (path, required): Application ID

**Response** (200 OK): Complete application object with microservices

#### PUT /api/application/{appid}
**Purpose**: Update existing application

**Parameters**:
- `appid` (path, required): Application ID

**Request Body**: Updated application definition

#### DELETE /api/application/{appid}
**Purpose**: Delete application and all its services

**Parameters**:
- `appid` (path, required): Application ID

### 3. Service Management Endpoints

#### GET /api/service/{serviceid}
**Purpose**: Get detailed service information

**Parameters**:
- `serviceid` (path, required): Service ID

**Response** (200 OK):
```json
{
  "microserviceID": "string",
  "microservice_name": "string",
  "microservice_namespace": "string", 
  "virtualization": "container",
  "memory": 100,
  "vcpus": 1,
  "vgpus": 0,
  "vtpus": 0,
  "bandwidth_in": 0,
  "bandwidth_out": 0,
  "storage": 0,
  "code": "docker.io/library/image:tag",
  "state": "string",
  "port": "8080:8080",
  "one_shot": false,
  "privileged": false,
  "cmd": ["string"],
  "environment": ["ENV_VAR=value"],
  "args": ["string"],
  "addresses": {
    "rr_ip": "10.30.x.x",
    "rr_ip_v6": "string",
    "closest_ip": "string",
    "closest_ip_v6": "string",
    "instances": [{"from": "string", "to": "string", "start": "string"}]
  },
  "added_files": ["string"],
  "constraints": [{
    "type": "direct|area|cluster",
    "area": "string",
    "cluster": "string", 
    "node": "string",
    "location": "string",
    "threshold": 0.0,
    "rigidness": 0.0,
    "convergence_time": 0,
    "needs": ["string"],
    "allowed": ["string"]
  }],
  "connectivity": [{
    "target_microservice_id": "string",
    "con_constraints": [{
      "type": "string",
      "threshold": 0.0
    }]
  }]
}
```

#### PUT /api/service/{serviceid}
**Purpose**: Update existing service configuration

#### DELETE /api/service/{serviceid}  
**Purpose**: Delete specific service

#### POST /api/service/
**Purpose**: Create new service within existing application

#### GET /api/services/{appid}
**Purpose**: Get all services for specific application

#### GET /api/services/
**Purpose**: Get all services for current user

### 4. Service Instance Management

#### POST /api/service/{serviceid}/instance
**Purpose**: Deploy new instance of service

**Authentication**: Required

**Behavioral Notes**:
- Creates additional instance of existing service
- Useful for scaling services horizontally

#### DELETE /api/service/{serviceid}/instance/{instance_number}
**Purpose**: Remove specific service instance

**Parameters**:
- `serviceid` (path, required): Service ID
- `instance_number` (path, required): Instance number to remove

### 5. User Management Endpoints

#### GET /api/users/
**Purpose**: List all users in organization

#### GET /api/user/{username}
**Purpose**: Get specific user details

#### POST /api/user/
**Purpose**: Create new user

#### PUT /api/user/{username}
**Purpose**: Update user information

#### DELETE /api/user/{username}
**Purpose**: Delete user account

#### GET /api/users/{organization_id}
**Purpose**: Get users in specific organization

### 6. Organization Management

#### GET /api/organization/
**Purpose**: Get current organization details

**Response** (200 OK):
```json
{
  "name": "string",
  "member": ["string"]
}
```

#### POST /api/organization/
**Purpose**: Create new organization

#### PUT /api/organization/{organizationid}
**Purpose**: Update organization

#### DELETE /api/organization/{organizationid}
**Purpose**: Delete organization

### 7. Cluster Management

#### GET /api/clusters/
**Purpose**: List all available clusters

**Authentication**: Required

**Behavioral Notes**:
- May return empty array if no clusters configured
- Shows cluster capacity and availability

#### GET /api/clusters/active
**Purpose**: List only active/available clusters

#### POST /api/information/{clusterid}
**Purpose**: Update cluster status and resource information

**Request Body**:
```json
{
  "cpu_percent": "string",
  "cpu_cores": "string",
  "gpu_cores": "string", 
  "gpu_percent": "string",
  "cumulative_memory_in_mb": "string",
  "number_of_nodes": "string",
  "virtualization": ["container"],
  "worker_groups": "string",
  "supported_addons": ["string"],
  "jobs": [{
    "system_job_id": "string",
    "status": "string",
    "instance_list": [{
      "instance_number": "string",
      "status": "string",
      "status_detail": "string",
      "publicip": "string"
    }]
  }]
}
```

### 8. Permissions and Scheduling

#### GET /api/permission/{username}
**Purpose**: Get user permissions and roles

**Response** (200 OK):
```json
{
  "roles": ["Admin", "Organization_Admin", "Application_Provider", "Infrastructure_Provider"]
}
```

#### POST /api/result/deploy
**Purpose**: Report deployment results to scheduler

**Request Body**:
```json
{
  "job_id": "string",
  "cluster_id": "string"
}
```

## SLA File Format Specification

### Validation Rules and Constraints

#### String Patterns (CRITICAL)
- **Application Names**: `^[a-zA-Z0-9]{1,30}$` (alphanumeric only, 1-30 chars)
- **Microservice Names**: `^[a-zA-Z0-9]{1,30}$` (alphanumeric only, 1-30 chars)
- **Namespaces**: `^[a-zA-Z0-9]{1,30}$` (alphanumeric only, 1-30 chars)
- **IP Addresses**: **MUST be in format 10.30.x.x** (required IP range)

#### Required Fields
- `sla_version`: Version string (e.g., "v2.0")
- `customerID`: Customer identifier
- `applications`: Array of application objects
- `application_name`: Application identifier
- `application_namespace`: Application namespace
- `microservices`: Array of microservice objects
- `microservice_name`: Service identifier
- `microservice_namespace`: Service namespace  
- `code`: Container image reference
- `virtualization`: Usually "container"

#### Default Values
- `one_shot`: false
- `privileged`: false
- `memory`: 100 (MB)
- `vcpus`: 1
- `vgpus`: 0
- `vtpus`: 0
- `bandwidth_in`: 0
- `bandwidth_out`: 0
- `storage`: 0

### Complete SLA Schema Template

```json
{
  "sla_version": "v2.0",
  "customerID": "Admin",
  "applications": [{
    "applicationID": "",
    "application_name": "myapp",
    "application_namespace": "myapp",
    "application_desc": "Application description",
    "microservices": [{
      "microserviceID": "",
      "microservice_name": "service1",
      "microservice_namespace": "myapp",
      "virtualization": "container",
      "description": "Service description",
      "memory": 100,
      "vcpus": 1,
      "vgpus": 0,
      "vtpus": 0,
      "bandwidth_in": 0,
      "bandwidth_out": 0,
      "storage": 0,
      "code": "docker.io/library/nginx:latest",
      "state": "",
      "port": "80:80",
      "one_shot": false,
      "privileged": false,
      "cmd": [],
      "environment": ["ENV_VAR=value"],
      "args": [],
      "addresses": {
        "rr_ip": "10.30.10.1",
        "rr_ip_v6": "fdff:2000::1"
      },
      "added_files": [],
      "constraints": [{
        "type": "direct",
        "node": "worker-node-1"
      }],
      "connectivity": []
    }]
  }]
}
```

### Constraint Types and Options

#### Placement Constraints
- `direct`: Deploy to specific node
  - Required: `node` field
- `area`: Deploy to specific geographical area
  - Required: `area` field  
- `cluster`: Deploy to specific cluster
  - Required: `cluster` field
- `location`: Deploy based on location requirements
  - Required: `location` field

#### Advanced Constraints
```json
{
  "type": "performance",
  "threshold": 0.8,
  "rigidness": 1.0,
  "convergence_time": 30,
  "needs": ["gpu", "high-memory"],
  "allowed": ["worker-node-1", "worker-node-2"]
}
```

## Behavioral Patterns and Lessons Learned

### Authentication Behavior
1. **Case Sensitivity**: Username "Admin" (not "admin") is required
2. **Token Lifespan**: Tokens expire in ~10 minutes, plan refresh strategy
3. **Organization Handling**: Organization field optional but useful for multi-tenant setups
4. **Error Response**: 401 Unauthorized for invalid credentials

### Deployment Behavior  
1. **Endpoint Correction**: Use `/api/application/` (not `/api/applications/`) for deployment
2. **Trailing Slashes**: API redirects, but include trailing slash for consistency
3. **Response Format**: Returns JSON string that requires parsing with `jq -r . | jq .`
4. **Conflict Handling**: 409 Conflict when application name already exists
5. **Atomic Operations**: Application creation includes all microservices

### Network and IP Management
1. **IP Range Restriction**: All IPs MUST be 10.30.x.x format (enforced)
2. **IP Uniqueness**: Each service needs unique IP within application
3. **Port Format**: Use "host:container" format (e.g., "8080:80")
4. **Service Discovery**: Services can reference each other by assigned IPs

### Error Handling Patterns
1. **Method Not Allowed (405)**: Check HTTP method and endpoint spelling
2. **Unprocessable Entity (422)**: Validation errors in request body
3. **Conflict (409)**: Resource already exists with same identifier
4. **Unauthorized (401)**: Token expired or invalid credentials

## Enhanced Deployment Automation

### Complete Deployment Function with Context Management
```bash
deploy_to_oakestra_with_context() {
    local sla_file="$1"
    local context_file="$2"
    local base_url="http://116.203.149.6:10000"
    
    # Load existing context
    local context="{}"
    if [ -f "$context_file" ]; then
        context=$(cat "$context_file")
    fi
    
    # Check if token is still valid
    local token=$(echo "$context" | jq -r '.auth_token // empty')
    local token_expires=$(echo "$context" | jq -r '.token_expires // empty')
    
    if [ -z "$token" ] || [ "$(date -d "$token_expires" +%s)" -lt "$(date +%s)" ]; then
        # Authenticate and get new token
        local auth_response=$(curl -s -X POST "$base_url/api/auth/login" \
            -H "Content-Type: application/json" \
            -d '{"username": "Admin", "password": "Admin", "organization": "default"}')
        
        token=$(echo "$auth_response" | jq -r '.token')
        
        if [ "$token" == "null" ]; then
            echo "Authentication failed"
            return 1
        fi
        
        # Update context with new token
        local expires=$(date -d "+9 minutes" --iso-8601=seconds)
        context=$(echo "$context" | jq --arg token "$token" --arg expires "$expires" \
            '.auth_token = $token | .token_expires = $expires')
    fi
    
    # Validate SLA file
    if ! jq empty "$sla_file" 2>/dev/null; then
        echo "Invalid JSON in SLA file"
        return 1
    fi
    
    # Check IP addresses are in correct range
    local invalid_ips=$(jq -r '.applications[].microservices[].addresses.rr_ip' "$sla_file" | \
        grep -v '^10\.30\.[0-9]\+\.[0-9]\+$' || true)
    
    if [ -n "$invalid_ips" ]; then
        echo "ERROR: Invalid IP addresses found. Must be in 10.30.x.x format:"
        echo "$invalid_ips"
        return 1
    fi
    
    # Deploy application
    local deploy_response=$(curl -s -X POST "$base_url/api/application/" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d @"$sla_file")
    
    # Parse deployment result
    local app_info=$(echo "$deploy_response" | jq -r . 2>/dev/null | jq .[0] 2>/dev/null)
    
    if [ "$app_info" == "null" ]; then
        echo "Deployment failed: $deploy_response"
        return 1
    fi
    
    # Update context with deployment info
    local app_name=$(echo "$app_info" | jq -r '.application_name')
    local app_id=$(echo "$app_info" | jq -r '.applicationID')
    local microservices=$(echo "$app_info" | jq -r '.microservices[]')
    
    # Store deployment in context
    context=$(echo "$context" | jq --arg name "$app_name" --arg id "$app_id" --arg timestamp "$(date --iso-8601=seconds)" \
        '.deployed_applications += [{"application_name": $name, "application_id": $id, "deployed_at": $timestamp, "status": "active"}]')
    
    # Save updated context
    echo "$context" > "$context_file"
    
    echo "Deployment successful!"
    echo "Application: $app_name"
    echo "Application ID: $app_id"
    echo "Microservices: $(echo "$microservices" | tr '\n' ' ')"
}
```

### Context-Aware Status Check
```bash
check_application_status_with_context() {
    local app_name="$1"
    local context_file="$2"
    local base_url="http://116.203.149.6:10000"
    
    # Load context to get app ID and token
    local context=$(cat "$context_file")
    local token=$(echo "$context" | jq -r '.auth_token')
    local app_id=$(echo "$context" | jq -r --arg name "$app_name" \
        '.deployed_applications[] | select(.application_name == $name) | .application_id')
    
    if [ -z "$app_id" ] || [ "$app_id" == "null" ]; then
        echo "Application $app_name not found in context"
        return 1
    fi
    
    # Get application status
    curl -s -H "Authorization: Bearer $token" \
        "$base_url/api/application/$app_id" | jq .
}
```

## Agent Instructions

### Mandatory Context Management
Agents MUST:

1. **Initialize Context**: Create context file at session start
2. **Load Context**: Check existing context before operations  
3. **Update Context**: Save state after successful operations
4. **Token Management**: Track token expiration and refresh automatically
5. **IP Tracking**: Maintain IP allocation table to prevent conflicts
6. **Operation Logging**: Record all operations with timestamps and results

### Pre-Operation Validation Checklist
- [ ] Load existing context and validate token
- [ ] Validate SLA JSON syntax with `jq`
- [ ] Check all IP addresses are in 10.30.x.x range
- [ ] Verify IP addresses are unique within application
- [ ] Validate naming conventions (alphanumeric, 1-30 chars)
- [ ] Check for required fields (application_name, microservice_name, code)
- [ ] Verify container images are accessible

### Post-Operation Context Updates
- [ ] Store application ID and microservice IDs
- [ ] Record IP allocations and port mappings
- [ ] Update deployment status and timestamps
- [ ] Log operation results and any errors
- [ ] Save updated context to persistent storage

### Error Recovery Patterns
1. **Token Expiration**: Automatically refresh using refresh token
2. **Conflict Errors**: Check context for existing deployments before retrying
3. **Network Issues**: Implement retry logic with exponential backoff
4. **Validation Failures**: Provide specific field-level error messages

## Integration with Acorn Benchmark System

The Oakestra deployment serves as target infrastructure for Acorn distributed benchmarking:

### Known Deployment State
Based on successful acmeair deployment:
- **Application ID**: 6898768499b4b515b1189e68
- **MongoDB**: Service ID 6898768499b4b515b1189e69, IP 10.30.10.11:27017
- **AuthService**: Service ID 6898768499b4b515b1189e6a, IP 10.30.10.1:9443  
- **AcmeAir**: Service ID 6898768499b4b515b1189e6b, IP 10.30.10.2:9080

### Chaos Engineering Integration
- Static IP assignments enable iptables-based traffic control
- Service IDs allow targeted instance management
- Resource constraints ensure predictable benchmark conditions
- Network topology supports realistic multi-tier application testing

Agents should coordinate Oakestra deployments with Acorn benchmark execution plans for comprehensive distributed system testing.

## Current Setup
Orchestrator node Public IP: 116.203.149.6 Private IP: 10.0.0.3
Worker node Public IP: 167.235.134.239 Private IP: 10.0.0.2

## Critical Networking Insights

### Oakestra's 3-Layer IP Architecture
Oakestra implements a sophisticated networking model with three distinct IP layers:

1. **Container Layer (`10.18.x.x`)**
   - Actual container networking within worker nodes
   - Managed by `goProxyBridge` interface
   - Example: MongoDB container gets `10.18.0.70`

2. **Instance Layer (`10.30.0.x`)**
   - Proxy/overlay layer for inter-node communication
   - Managed by NetManager for routing
   - Example: MongoDB instance IP `10.30.0.8`

3. **Service Layer (`10.30.10.x`, `10.30.55.x`)**
   - User-configured service IPs (like Kubernetes Services)
   - Should be translated via TUN interface proxy conversion
   - Example: MongoDB service IP `10.30.10.11`

### Service IP Proxy Conversion Mechanism
- **TUN Interface**: `goProxyTun` intercepts traffic to `10.30.x.x` ranges
- **Translation Table**: NetManager maintains service IP → container IP mappings
- **Routing Critical**: Traffic must flow through TUN, not bridge, for proxy conversion

### Known Proxy Conversion Issue & Fix
**Problem**: NetManager may incorrectly add service IPs to bridge interface, causing traffic bypass.

**Symptoms**:
- Service IPs unreachable from containers
- Bridge interface shows service IPs as local addresses
- Bridge routes like `10.30.10.0/24 dev goProxyBridge` exist

**Fix**:
```bash
# Remove service IPs from bridge interface
ip addr del 10.30.10.11/32 dev goProxyBridge
ip addr del 10.30.10.1/32 dev goProxyBridge  
ip addr del 10.30.10.2/32 dev goProxyBridge

# Remove incorrect bridge route
ip route del 10.30.10.0/24 dev goProxyBridge

# Clear manual DNAT rules if present
iptables -t nat -F OAKESTRA
```

**Verification**: Service IPs should route via `10.16.0.0/12 dev goProxyTun`

### Cross-Node Communication Architecture
**Critical**: Cross-node proxy conversion uses **public IP addresses** for inter-node communication, not private network.

**Configuration**: `/etc/netmanager/netcfg.json`
```json
{
  "NodePublicAddress": "0.0.0.0",  // Defaults to public interface
  "NodePublicPort": "50103",
  "ClusterUrl": "0.0.0.0", 
  "ClusterMqttPort": "10003"
}
```

**Implications**:
- Cross-node traffic: `116.203.149.6` ↔ `167.235.134.239` (public IPs)
- Same-node traffic: Local TUN/bridge (private)
- **Firewall Requirements**: Nodes must allow traffic between public IPs on port 50103

**Firewall Fix** (temporary):
```bash
# Allow NetManager communication between nodes (UDP protocol required)
iptables -A INPUT -s 116.203.149.6 -p udp --dport 50103 -j ACCEPT
iptables -A INPUT -s 167.235.134.239 -p udp --dport 50103 -j ACCEPT

# For cloud providers like Hetzner, configure firewall to allow UDP 50103 between node public IPs:
# - Source: 116.203.149.6 (orchestrator) → Destination: 167.235.134.239 (worker) UDP:50103
# - Source: 167.235.134.239 (worker) → Destination: 116.203.149.6 (orchestrator) UDP:50103
```

**Optimal Configuration** (recommended):
```json
{
  "NodePublicAddress": "10.0.0.3",  // Use private IP
  "ClusterUrl": "10.0.0.3"           // Use private IP for cluster
}
```

### Debugging Cross-Node Issues
When services deployed on different nodes cannot communicate:

1. **Check service registration**: Verify in MongoDB service database
2. **Test same-node connectivity**: Ensure proxy conversion works locally
3. **Verify firewall rules**: Cross-node traffic uses public IPs
4. **Check NetManager logs**: Look for MQTT/cluster communication errors
5. **Validate routing**: Ensure TUN interface handles service IP ranges

### MongoDB State Databases
Oakestra maintains service state in MongoDB:
- **Service Networking**: `mongodb://116.203.149.6:10008/`
- **Node Networking**: `mongodb://116.203.149.6:10108/`  
- **Application State**: `mongodb://116.203.149.6:10007/`

These databases contain the complete service registration and routing information for debugging networking issues. 