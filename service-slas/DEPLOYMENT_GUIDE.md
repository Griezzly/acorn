# Acme Air Deployment Guide

This document provides comprehensive deployment instructions for the Acme Air Node.js application across Docker and Oakestra orchestration platforms.

## Application Architecture

**Acme Air** is a sample airline booking application with microservice architecture:
- **Main Application**: Express.js server handling web UI and business logic
- **Auth Service**: Dedicated authentication microservice  
- **MongoDB**: Database for customer, flight, and booking data

### Key Components
- `app.js`: Main application entry point (port 9080)
- `authservice_app.js`: Authentication service (port 9443)
- MongoDB 4.x: Document database (port 27017)

## Docker Deployment

### Working Configuration (Tested & Validated)

#### 1. Network Setup
```bash
# Create dedicated Docker network for proper container communication
docker network create acmeair-network
```

#### 2. MongoDB Deployment  
```bash
docker run --name mongo_acmeair -d \
  --network acmeair-network \
  -p 27017:27017 \
  mongo:4
```

#### 3. Auth Service Deployment
```bash
docker run -d --name acmeair_auth \
  --network acmeair-network \
  -p 9443:9443 \
  -e APP_NAME=authservice_app.js \
  -e MONGO_URL=mongodb://mongo_acmeair:27017/acmeair \
  acmeair/web
```

#### 4. Main Application Deployment
```bash
docker run -d --name acmeair_main \
  --network acmeair-network \
  -p 9080:9080 \
  -e AUTH_SERVICE=acmeair_auth:9443 \
  -e MONGO_URL=mongodb://mongo_acmeair:27017/acmeair \
  acmeair/web
```

#### 5. Database Initialization
```bash
# Load sample data (10k customers, flight data)
curl -X GET http://localhost:9080/rest/api/loader/load
```

#### 6. Validation
```bash
# Test login with sample credentials
curl -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "login=uid0@email.com&password=password" \
  http://localhost:9080/rest/api/login
```

### Critical Environment Variables
- **AUTH_SERVICE**: `acmeair_auth:9443` (container name for Docker networking)
- **MONGO_URL**: `mongodb://mongo_acmeair:27017/acmeair` (includes database name)
- **APP_NAME**: `authservice_app.js` (for auth service container)

## Oakestra Deployment

### Manifest Configuration (acmeair.json)

The Oakestra deployment uses static IP allocation with the following topology:

```
MongoDB:      10.30.10.11:27017  (500MB RAM, 1 CPU)
Auth Service: 10.30.10.1:9443    (100MB RAM, 1 CPU)  
Main App:     10.30.10.2:9080    (100MB RAM, 1 CPU)
```

#### Service Definitions

**MongoDB Service:**
```json
{
  "microservice_name": "mongodb",
  "code": "docker.io/library/mongo:4",
  "port": "27017:27017",
  "addresses": {"rr_ip": "10.30.10.11"},
  "memory": 500, "vcpus": 1
}
```

**Auth Service:**
```json
{
  "microservice_name": "authservice", 
  "code": "docker.io/schubbcasten/acmeair-nodejs:v0.0.4-x86",
  "port": "9443:9443",
  "addresses": {"rr_ip": "10.30.10.1"},
  "environment": [
    "APP_NAME=authservice_app.js",
    "MONGO_URL=mongodb://10.30.10.11:27017/acmeair"
  ],
  "memory": 100, "vcpus": 1
}
```

**Main Application:**
```json
{
  "microservice_name": "acmeair",
  "code": "docker.io/schubbcasten/acmeair-nodejs:v0.0.4-x86", 
  "port": "9080:9080",
  "addresses": {"rr_ip": "10.30.10.2"},
  "environment": [
    "AUTH_SERVICE=10.30.10.1:9443",
    "MONGO_URL=mongodb://10.30.10.11:27017/acmeair"
  ],
  "memory": 100, "vcpus": 1
}
```

### Deployment Steps
1. Deploy the complete `acmeair.json` manifest via Oakestra
2. Wait for all services to be running and healthy
3. Initialize database: `curl -X GET http://10.30.10.2:9080/rest/api/loader/load`
4. Test application: Access `http://10.30.10.2:9080/`

## Troubleshooting Guide

### Common Issues & Solutions

#### 1. Database Connection Failures
**Symptoms**: "topology destroyed", "sockets closed" errors
**Root Cause**: Network connectivity between containers
**Solution**: Ensure proper networking setup (Docker network or static IPs in Oakestra)

#### 2. Authentication 404 Errors  
**Symptoms**: POST requests to auth service return 404
**Root Cause**: Auth service misconfiguration or networking
**Solution**: Verify AUTH_SERVICE environment variable points to correct host:port

#### 3. Empty Database After Loading
**Symptoms**: Database load completes but no collections created
**Root Cause**: Missing database name in MONGO_URL
**Solution**: Always include `/acmeair` at end of MongoDB connection string

#### 4. Login Returns 400/500 Errors
**Symptoms**: Valid credentials rejected during login
**Root Cause**: Database connectivity or missing sample data
**Solution**: 
1. Verify database connection with ping
2. Reload sample data via `/rest/api/loader/load`
3. Check MongoDB collections exist: `customer`, `flight`, `booking`

### Validation Commands

```bash
# Check MongoDB collections
docker exec <mongo-container> mongo acmeair --eval "db.getCollectionNames()"

# Verify customer data
docker exec <mongo-container> mongo acmeair --eval "db.customer.findOne()"

# Test auth service directly  
curl -X POST http://<auth-host>:9443/acmeair-auth-service/rest/api/authtoken/byuserid/uid0@email.com

# Test main app health
curl -X GET http://<main-host>:9080/rest/api/checkstatus
```

## Sample Data

After database loading, the following test accounts are available:
- **Usernames**: `uid0@email.com` through `uid9999@email.com` 
- **Password**: `password` (all accounts use same password)
- **Data**: 10,000 customers, 5 days of flight schedules, sample airports

## Key Lessons Learned

1. **Database Name is Critical**: Must specify `/acmeair` in all MONGO_URL variables
2. **Container Networking**: Docker containers need dedicated network for reliable communication  
3. **Service Dependencies**: Auth service must be accessible before main app starts accepting requests
4. **Resource Allocation**: 100MB RAM sufficient for Node.js services, 500MB for MongoDB
5. **Environment Consistency**: All services must use same database configuration

## Future Considerations

- **Persistence**: Add volume mounts for MongoDB data persistence
- **Scaling**: Configure multiple replicas for auth service and main app
- **Monitoring**: Add health checks and logging aggregation
- **Security**: Implement proper authentication between services
- **Performance**: Consider connection pooling and caching optimizations
