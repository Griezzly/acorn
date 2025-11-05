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

# Documentation of Oakestra-SLA (v0.3.2)
Example under *sla.json*

- **api_version** : Version of SLA API; v0.3.2 as of now
- **customerID** : ID of the customer
- **args** : *see "On expandability"*
- **applications** : List of applications run by the customer
    - **applicationID** : ID of the application described,
    - **application_name** : Name of the application
    - **application_namespace** : (Optional) : Namespace of the application
    - **application_desc** : Description of the application
    - **microservices** : List of microservices this application needs
        - **microserviceID** : ID of a microservice; automatically generated (UUID)
        - **microservice_name** : Name of the microservice; used for addressing
        - **microservice_namespace** : Optional - User may specify a name to be used in the address of the microservice (if it is still available)
        - **virtualization** : type of virtualization chosen for the application, may be one of ["container", "unikernel", "vm"]
        - **memory** : Needed memory in MB,
        - **vcpus** : Needed vCPUs, default 1
        - **vgpus** : Needed vGPUs, default 0
        - **vtpus** : Needed vTPUs, default 0
        - **bandwidth_in** : Minimum bandwidth-ingress needed for application in kbit/s, default 0
        - **bandwith_out** : Minimum bandwidth-egress needed for application in kbit/s, default 0
        - **storage** : Permanent Storage needed in MB, default 0
        - **code** : File containing the code; given as URL
        - **state** : File containing the state; given as URL; default empty
        - **port** : Port for exposure of the microservice chosen by the developer
        - **one_shot** : Bool that represents if a service should be restarted if it terminates or not.
        - **privileged** : Bool that represents if a service should use additional NodeEngine (containerd) privileges and rights.
        - **addresses** : Optional - ***[Taken from Giovanni's and Mehdi's design; more details in On addressess]***
            - **rr_ip** : Optional - IP chosen for round-robin addressation
            - **closest_ip** : Optional - The orchestrator may choose the closest IP to the given one
            - **instances** : Optional - Field of instances
                - **from**
                - **to**
                - **start**
        - **added_files** : List of added files necessary, can be configured by the developer
            - **url** : URL of a file, that the developer needs to have added to the microservice
        - **args** : *see "On expandability"*
        - **constraints** : List of constraints that need to be applied
            - **type** : Type of constraint; one of ["latency", "geo", "addons", "clusters"]
                - ***For type "latency"***
                - **area** : Specifies the area in which the constraint is in effect; must be chosen from a list of predefined areas (Mainly urban areas)
                - **threshold** : Maximum latency in [ms],
                - **rigidness** : Rigidness of constraint; If [**rigidness**] * [recent_requests] > [successfull_recent_requests], the constraint is counted as failed: *Example*: rigidness of 1 implies the first failure to meet goals triggers an alarm. rigidness of 0.99 implies that 99% (or more) of recent requests must satisfy the constraint, otherwise an alarm gets triggered.
                - **convergence_time** : Time the orchestration framework has to find the optimal solution, before the [**rigidness**] of the constraint gets measured. In [s], default 300 (5 min)
                - ***For type "geo", see "About geo"***
                - **location** : Specifies the location close to which the service should be deployed (as a tuple of (longitude; latitude))
                - **threshold** : Maximum distance from location in [km],
                - **rigidness** : Rigidness of constraint; If [**rigidness**] * [recent requests] > [successfull recent requests], the constraint is counted as failed: *Example*: rigidness of 1 implies the first failure to meet goals triggers an alarm. rigidness of 0.99 implies that 99% (or more) of recent requests must satisfy the constraint, otherwise an alarm gets triggered.
                - **convergence_time** : Time the orchestration framework has to find the optimal solution, before the [**rigidness**] of the constraint gets measured. In [s], default 300 (5 min)
                - ***For type "addons"***
                - **needs** : ["addon_1", "addon_2"] : Allows service placement only on worker nodes where both addons are installed.
                - ***For type "clusters"***
                - **allowed** : ["cluster_name_1", "cluster_name_2"] : Allows service placement only on clusters mentioned in the allowed list.
        - **connectivity** : List of connections this microservice needs to make to other microservices of the application and constraints that have to be satisfied; for more information read ***On conectivity***
            - **target_microservice_id** : ID of the microservice this microservice needs to communicate with.
            - **con_constraints** : List of connectivity constraints
                - **type** : Type of constraint; one of ["latency", "bandwidth"]
                    - **threshold** : For "latency" maximum latency of the connection in [ms]; for "bandwidth" minimum bandwidth in [kbit/s]
                    - **rigidness** : Rigidness of constraint; see definition in constraint.
                    - **convergence_time** : Time the orchestration framework has to find the optimal solution, before the [**rigidness**] of the constraint gets measured. In [s], default 300 (5 min)

## On expandability

There are multiple points for this design to be expanded upon:

First, both the customer and its applications can be expanded upon with multiple further arguments, either in place of or as a dictionary in the field "args" (present both in the "customer"-object and the "application"-object, though obviously not referencing the exact same type)

### Constraints

Secondly, a main point to expand this SLA-scheme is by adding constraint-types: All constraints listed under the "constraints"-attribute must be fulfilled (according to their "rigidness") to not trigger the alarm. This way one might i.e. create coverage for bigger areas than just one predefined area: by adding one latency constraint for the area "munich-1" and another one for area "berlin-1", he can consequently define coverage of his application for multiple areas.

The **convergence_time** is the time the orchestration framework has, to find one (or more) suitable nodes to deploy the microservice to. During this initial time, the rigidness of the constraint is not enforced. A higher **convergence_time** might result in better and maybe even fewer nodes being chosen for the service, whereas a low one might result in the system being "overly careful" right away and deploying on more nodes just to make sure, before figuring out the best option.

## On connectivity

This attribute is designed to define the ways a developer might want to specify, how his different microservices communicate within an application.

Firstly, the developer specifies a list of microserviceIDs he wants to communicate with. For example if microsevice 4 (which we are configuring right now) needs to communicate with microservices 1 and 2, he lists them here.

Furthermore, the developer can now also specify constraints, that the placement of the microservices must satisfy. For example, while microservices 4 and 1 have no constraints whatsoever to fulfill, microservices 4 and 2 have to be able to communicate with at most 50 ms latency at least 90% of the time. This can be specified under the field **con_constraints** using the latency-type.

This example of connectivity is "fleshed out" in the demo ***sla.json***

**Note**: This way of defining connectivity always assumes bidirectional connections. In case there are contradictions in a connection, i.e. microservice 4 -> 1 is defined with maximum 30 ms; microservice 1 -> 4 is defined with maximum 50 ms (or not defined at all), the scheduler should assume connectivity and take the tighter constraint (30 ms).

## On addresses

These fields are added on the account of Giovanni, who introduced them together with Mehdi to allow developers to choose an IP address their microservice should be available at, in case it is unoccupied.

