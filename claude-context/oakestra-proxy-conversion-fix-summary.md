# Oakestra Service IP Proxy Conversion Issue - Root Cause Analysis & Fix

## 🚨 What Went Wrong

**NetManager incorrectly configured AcmeAir services with bridge-based routing instead of TUN-based proxy conversion**, while nginx used the correct TUN-based approach.

### The Problem Chain

1. **Incorrect Bridge Configuration**
   - NetManager added AcmeAir service IPs (`10.30.10.1`, `10.30.10.2`, `10.30.10.11`) directly to the `goProxyBridge` interface
   - Created a bridge route: `10.30.10.0/24 dev goProxyBridge`

2. **Traffic Bypass**
   - AcmeAir traffic was routed directly through the bridge instead of the TUN interface
   - This bypassed the proxy conversion mechanism entirely
   - Traffic flow: Container → Bridge → Manual DNAT rules (which were broken)

3. **nginx Worked Because**
   - nginx service IP (`10.30.55.55`) was NOT added to the bridge
   - No specific bridge route for `10.30.55.x` range
   - Traffic correctly flowed: Container → TUN → Proxy Conversion → Target Container

## 🔍 How We Diagnosed It

### Initial Confusion
- **First thought**: Proxy conversion wasn't implemented
- **Database investigation**: Found all services perfectly registered
- **Connectivity tests**: Discovered asymmetric behavior (nginx worked, AcmeAir didn't)

### Key Breakthrough
- **MongoDB analysis**: Revealed 3-layer IP architecture and perfect service registration
- **IPv6 theory**: Tested and disproven
- **Routing investigation**: Found the smoking gun - incorrect bridge routes

### The Smoking Gun
```bash
# Wrong routing for AcmeAir
10.30.10.0/24 dev goProxyBridge scope link    # ❌ Traffic goes to bridge

# Correct routing for nginx  
10.16.0.0/12 dev goProxyTun                   # ✅ Traffic goes to TUN
```

## ✅ How We Fixed It

### The Fix (3 simple commands)
```bash
# Remove service IPs from bridge interface
ip addr del 10.30.10.11/32 dev goProxyBridge
ip addr del 10.30.10.1/32 dev goProxyBridge  
ip addr del 10.30.10.2/32 dev goProxyBridge

# Remove incorrect bridge route
ip route del 10.30.10.0/24 dev goProxyBridge

# Clear broken manual DNAT rules
iptables -t nat -F OAKESTRA
```

### Result
- ✅ **All AcmeAir service IPs now work**
- ✅ **Traffic flows through proper TUN interface**
- ✅ **Proxy conversion mechanism functions correctly**
- ✅ **nginx continues to work**

## 🎯 Root Cause Analysis

**The issue was NOT:**
- ❌ Missing proxy conversion implementation
- ❌ Service registration failure  
- ❌ IPv6 configuration requirement
- ❌ NetManager translation table problems

**The issue WAS:**
- ✅ **Incorrect routing configuration** that bypassed the proxy conversion mechanism for specific service IP ranges

## 💡 Key Insights

1. **Oakestra has a sophisticated 3-layer IP architecture** that was working correctly
2. **The proxy conversion mechanism was functional** - just bypassed by wrong routes
3. **Service registration was perfect** - visible in MongoDB databases
4. **Asymmetric behavior** was the key clue that led to the routing investigation
5. **Simple routing fixes** resolved what appeared to be a complex networking issue

## 🏗️ Oakestra's 3-Layer IP Architecture

Based on our investigation, Oakestra uses a sophisticated networking model:

### Layer 1: Container Network (`10.18.x.x`)
- **Purpose**: Actual container networking within worker nodes
- **Management**: Handled by `goProxyBridge` interface
- **Example**: MongoDB container gets `10.18.0.70`

### Layer 2: Instance Network (`10.30.0.x`)
- **Purpose**: Proxy/overlay layer for inter-node communication
- **Management**: Managed by NetManager for routing
- **Example**: MongoDB instance IP `10.30.0.8`

### Layer 3: Service Network (`10.30.10.x`, `10.30.55.x`)
- **Purpose**: User-configured service IPs (like Kubernetes Services)
- **Management**: Should be translated via TUN interface proxy conversion
- **Example**: MongoDB service IP `10.30.10.11`

## 🔧 Technical Details

### Correct Traffic Flow (nginx)
```
Client Container (10.18.0.x)
    ↓ Request to 10.30.55.55
    ↓ Route: 10.16.0.0/12 dev goProxyTun
    ↓ TUN Interface intercepts traffic
    ↓ NetManager proxy conversion
    ↓ Translation table lookup
    ↓ Converts to instance IP 10.30.0.6
    ↓ Forwards to nginx container 10.18.0.69
```

### Broken Traffic Flow (AcmeAir - before fix)
```
Client Container (10.18.0.x)
    ↓ Request to 10.30.10.11
    ↓ Route: 10.30.10.0/24 dev goProxyBridge
    ↓ Bridge interface (bypasses TUN)
    ↓ Manual DNAT rules (broken)
    ❌ Connection fails
```

### Fixed Traffic Flow (AcmeAir - after fix)
```
Client Container (10.18.0.x)
    ↓ Request to 10.30.10.11
    ↓ Route: 10.16.0.0/12 dev goProxyTun
    ↓ TUN Interface intercepts traffic
    ↓ NetManager proxy conversion
    ↓ Translation table lookup
    ↓ Converts to instance IP 10.30.0.8
    ✅ Forwards to MongoDB container 10.18.0.70
```

## 📊 Before vs After

| Component | Before Fix | After Fix |
|-----------|------------|-----------|
| **AcmeAir Service IPs** | ❌ Unreachable | ✅ Working |
| **nginx Service IP** | ✅ Working | ✅ Working |
| **Routing for 10.30.10.x** | Bridge (wrong) | TUN (correct) |
| **Proxy Conversion** | Bypassed | Functional |
| **Inter-service Communication** | Failed | Success |

## 🔍 Diagnostic Commands Used

```bash
# Key routing investigation
ip route show table all | grep -E "10\.30\.|goProxyTun"

# Bridge interface analysis
ip addr show goProxyBridge

# Service connectivity tests
timeout 3 bash -c "</dev/tcp/10.30.10.11/27017"

# Database investigation
mongosh mongodb://116.203.149.6:10008/jobs --eval "db.jobs.find({}).toArray()"
```

## 🎯 Conclusion

This demonstrates how **network routing configuration errors** can make functional systems appear completely broken, and how systematic debugging can identify the precise issue even in complex distributed systems.

**Key Takeaway**: When debugging networking issues in orchestration platforms, always investigate the actual packet flow and routing configuration, not just the application-layer symptoms.

---

*This analysis was conducted through systematic investigation of Oakestra's networking internals, MongoDB state databases, and packet flow analysis.*