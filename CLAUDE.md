# Technical Specifications - Local Kubernetes Cluster Deployment

## Overview

This project provides automated tooling for deploying a multi-API microservices stack to a local Kubernetes cluster running on Docker Desktop. It orchestrates the deployment of multiple backend APIs, a frontend UI, infrastructure dependencies, and mock services for development and testing purposes.

## Architecture

### System Type
- **Deployment Tool**: Bash-based orchestration script for local Kubernetes development environment
- **Target Platform**: Docker Desktop Kubernetes cluster
- **Environment**: Local development and testing only (not production-ready)

### Core Components

#### 1. Real Application Services (5)
Located in parent directory relative to this project:

- **management-plane-api** (Port 8000)
  - Primary management plane service
  - Depends on: etcd, Authentik

- **operational-api** (Port 8080)
  - Operational data service
  - Depends on: Prometheus, Valkey, OpenExchangeRates, ZTAC gRPC service, Authentik

- **tenant-auth-management-api** (Port 8082)
  - Tenant authentication management
  - Depends on: Authentik groups configuration

- **ztac-ip-reputation-engine-service** (Ports 4317, 9090, 8080)
  - Zero Trust Access Control IP reputation engine
  - Port 4317: OTLP (OpenTelemetry Protocol) receiver for authentication logs
  - Port 9090: gRPC API for IP reputation queries
  - Port 8080: Prometheus metrics endpoint
  - Depends on: Valkey, Management API
  - **Note**: Requires Alloy agents (not currently deployed) to send authentication logs

- **core-ui** (Port 3000)
  - Frontend web application (can run locally with hot reload)
  - Depends on: All backend APIs

#### 2. Infrastructure Dependencies (4)

- **etcd** (Port 2379)
  - Distributed key-value store
  - Image: `quay.io/coreos/etcd:v3.5.9`
  - Persistent storage: 1Gi PVC at `/etcd-data`

- **valkey** (Port 6379)
  - Redis-compatible in-memory cache
  - Image: `valkey/valkey:7.2-alpine`
  - Persistent storage: 1Gi PVC at `/data`

- **prometheus** (Port 19090)
  - Metrics collection and storage
  - Image: `prom/prometheus:latest`
  - Persistent storage: 1Gi PVC at `/prometheus`
  - Custom scrape configuration via ConfigMap

- **pushgateway** (Port 19091)
  - Prometheus push endpoint for batch/ephemeral metrics
  - Image: `prom/pushgateway:latest`

#### 3. Mock Services (2)

- **openexchangerates-mock** (Port 8080)
  - Simulates OpenExchangeRates currency API
  - Returns ~20 currencies with ±2% random variation
  - Endpoint: `/api/latest.json`
  - Technology: Python Flask

- **prometheus-data-generator** (Port 12345)
  - Generates synthetic network traffic metrics
  - Pushes to Pushgateway every 15 seconds
  - Metrics: `cnstraffic_interface_rx_bytes` with multiple labels
  - Technology: Python with prometheus_client

### External Dependencies

**Authentik Authentication Service**
- External OAuth2/OIDC provider (not deployed by this tool)
- Required configuration in `config/local-k8s-env.yml`:
  - `AUTHENTIK_URL`
  - `AUTHENTIK_ISSUER`
  - `JWKS_URL`
  - `AUTHENTIK_CLIENT_ID`
  - `AUTHENTIK_CLIENT_SECRET`

## ZTAC IP Reputation Engine Architecture

The ZTAC (Zero Trust Access Control) IP Reputation Engine is a critical security component that tracks authentication attempts and blocks malicious IP addresses based on failure patterns.

### How ZTAC Works

#### Data Flow
```
Alloy Agents → OTLP (port 4317) → ZTAC Service → Valkey (storage)
                                       ↓
                              Management API (config/allow-lists)
                                       ↓
                              gRPC API (port 9090) ← Application Services
```

### Components and Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 4317 | gRPC (OTLP) | Receives authentication logs from Alloy agents |
| 9090 | gRPC | API for IP reputation queries (GetIPReputation, GetRemoteLogCollectors) |
| 8080 | HTTP | Prometheus metrics endpoint |

### Data Sources

#### 1. Remote Log Collectors (Alloy Agents)

**Status**: NOT currently deployed in this stack

**Purpose**: Grafana Alloy agents collect authentication logs from applications and send them to ZTAC.

**How they work**:
- Deploy Alloy as a DaemonSet or sidecar alongside application pods
- Alloy scrapes authentication logs from services (e.g., failed login attempts)
- Sends data to `ztac-ip-reputation-engine-service:4317` via OTLP over gRPC
- Uses `X-Scope-OrgId` header to identify the tenant
- Agents are automatically discovered when they first send data (no pre-registration)
- Each agent identified by `service.name` in OTLP resource attributes

**Agent Metadata** (stored in Valkey):
- UUID (unique identifier)
- Name (service name from OTLP attributes)
- IP address
- Last seen timestamp
- Optional description
- Retrieved via: `GetRemoteLogCollectors()` gRPC call on port 9090

**To add Alloy agents to this deployment**:
1. Add Alloy to the `DEPENDENCIES` array in `deploy.sh`
2. Configure Alloy to scrape authentication logs from services
3. Set OTLP exporter to `ztac-ip-reputation-engine-service:4317`
4. Configure `X-Scope-OrgId` header for tenant identification

#### 2. Automatic Block Lists

**Source**: Management API service (`management-plane-api`)

**Two types of lists**:

1. **Always-Allowed List** (`alwaysAllowed`):
   - IPs that should never be blocked (e.g., admin IPs, corporate networks)
   - Fetched from: `GET /tenants/{tenant-slug}/ztac/ztac-config`
   - Supports CIDR notation
   - Cached for 3 hours (configurable via `CONFIG_CACHE_TTL_SECONDS`)

2. **Dynamic Blocked IPs**:
   - Automatically generated by ZTAC engine when failures exceed threshold
   - Stored in Valkey with TTL expiration
   - No external source needed (generated internally)

**Configuration Endpoint Format**:
```
GET /tenants/{tenant-slug}/ztac/ztac-config

Response:
{
  "spec": {
    "enabled": true,
    "loginFailureThreshold": 5,
    "detectionPeriod": 30,
    "blockPeriod": 24,
    "alwaysAllowed": [
      {"cidr": "10.0.0.0/16", "description": "Corporate network"}
    ]
  }
}
```

**Configuration Parameters**:
- `loginFailureThreshold`: Number of failed attempts before blocking
- `detectionPeriod`: Time window (minutes) to count failures
- `blockPeriod`: How long (hours) to block the IP
- `alwaysAllowed`: List of CIDR ranges to never block

### Environment Variables

ZTAC service requires:
- `VALKEY_HOST`: Valkey/Redis host for data storage (default: `valkey`)
- `VALKEY_PORT`: Valkey port (default: `6379`)
- `MGMT_API_BASE_URL`: Management API URL for fetching ZTAC configs
- `CONFIG_CACHE_TTL_SECONDS`: Config cache duration (default: 10800 = 3 hours)

### Integration with Other Services

**operational-api** uses ZTAC:
- Calls `ztac-ip-reputation-engine-service:9090` via gRPC
- Checks IP reputation before processing requests
- Environment variable: `ZTAC_GRPC_URL=ztac-ip-reputation-engine-service:9090`

**management-plane-api** provides:
- ZTAC configuration per tenant
- Always-allowed IP lists
- ZTAC enable/disable toggle

### Deployment Status

**All Components Deployed**: Grafana Alloy agent, mock authentication service, and ZTAC are operational.

#### How The System Works

1. **auth-log-generator** (mock service) generates realistic authentication logs:
   - Legitimate users (192.168.1.*, 10.0.1.*) with ~90% success rate
   - Attacker IPs (203.0.113.*, 198.51.100.88) with ~90% failure rate
   - Multiple tenants: patmon, perimara, demo-tenant

2. **Grafana Alloy** collects and transforms logs:
   - Discovers pods with label `app=auth-log-generator`
   - Extracts authentication data from JSON logs
   - Transforms to ZTAC format: `{"UserName":"...","Status":"SUCCESS/FAILURE","SourceIP":"..."}`
   - Sends via OTLP to `ztac-ip-reputation-engine-service:4317`
   - Configuration: `config/alloy/config.alloy`

3. **ZTAC** processes authentication events:
   - Extracts auth events from OTLP log bodies
   - Registers remote log collectors by `service.name` attribute
   - Tracks authentication failures per IP address
   - Automatically blocks IPs exceeding failure threshold
   - Respects always-allowed lists from Management API

#### Required: Enable ZTAC for Tenants

**IMPORTANT**: ZTAC must be **enabled** in each tenant's configuration.

Check current status:
```bash
curl -H "X-Scope-OrgId: patmon" http://localhost:8000/tenants/patmon/ztac/ztac-config
```

Look for `"enabled": true`. If disabled (`"enabled": false`), update the configuration by:
1. Adding PUT/PATCH endpoint to management-plane-api, OR
2. Updating configuration directly in etcd, OR
3. Modifying seed data to enable ZTAC by default

Example enabled configuration:
```json
{
  "spec": {
    "enabled": true,
    "loginFailureThreshold": 5,
    "detectionPeriod": 30,
    "blockPeriod": 24
  }
}
```

### Required Components Summary

| Component | Purpose | Port | Status |
|-----------|---------|------|--------|
| Valkey/Redis | Data storage for IP reputation | 6379 | ✅ Deployed |
| Management API | ZTAC configs & allow-lists | 8000 | ✅ Deployed |
| ZTAC Service | IP reputation engine | 4317, 9090, 8080 | ✅ Deployed |
| Alloy Agent | Log collection from apps | - | ✅ Deployed |
| Mock Auth Service | Generate test auth logs | - | ✅ Deployed |

## Project Structure

```
local-k8s-cluster-deploy/
├── deploy.sh                          # Main deployment orchestration script
├── README.md                          # User documentation
├── CLAUDE.md                          # This technical specification
├── .gitignore                         # Git ignore rules
│
├── config/
│   ├── local-k8s-env.yml             # Environment variables (gitignored)
│   ├── local-k8s-env.yml.example     # Template for env vars
│   └── prometheus-config.yml         # Prometheus scrape configuration
│
├── mocks/
│   ├── openexchangerates-mock/
│   │   ├── Dockerfile
│   │   ├── mock_server.py            # Flask server for currency rates
│   │   └── secrets/
│   │       └── credentials.json      # Dummy API key (tracked in git)
│   │
│   └── prometheus-data-generator/
│       ├── Dockerfile
│       └── generate_metrics.py       # Synthetic metrics generator
│
├── secrets/
│   └── openexchangerates/
│       └── credentials.json          # Dummy credentials for volume mount
│
└── manifests/                        # Generated K8s manifests (gitignored)
    ├── *.yaml                        # Auto-generated deployment manifests
    └── (created by deploy.sh)
```

## Deploy Script (deploy.sh)

### Script Architecture

**Language**: Bash
**Mode**: Strict error handling (`set -e`)

### Key Functions

1. **Dependency Checking**
   - Verifies `yq` (YAML processor) is installed
   - Checks for `config/local-k8s-env.yml`
   - Validates kubectl context is `docker-desktop`

2. **Docker Image Building**
   - Builds images from Dockerfiles in each service directory
   - Tags images with `:latest`
   - Uses `imagePullPolicy: Never` to ensure local images are used

3. **Manifest Generation**
   - Dynamically generates Kubernetes YAML manifests
   - Injects environment variables from `config/local-k8s-env.yml`
   - Creates PersistentVolumeClaims for stateful services
   - Configures ConfigMap volume mounts

4. **Namespace Management**
   - Creates namespaces if they don't exist
   - Currently all services deploy to `default` namespace

5. **ConfigMap Management**
   - Creates ConfigMaps from files
   - Mounts as volumes in pods at specified paths

6. **Deployment**
   - Applies generated manifests to Kubernetes
   - Waits for pods to be ready
   - Shows deployment status

### Configuration Data Structures

#### APIS Array
```bash
declare -A APIS=(
    ["api-name"]="directory:image-name:port:namespace"
)
```

#### DEPENDENCIES Array
```bash
declare -A DEPENDENCIES=(
    ["service-name"]="image:container-port:service-port:namespace"
)
```

#### CONFIGMAPS Array
```bash
declare -A CONFIGMAPS=(
    ["configmap-name"]="namespace:source-file:mount-path:target-service"
)
```

### Command Line Options

```bash
# Deploy all services
./deploy.sh

# Deploy specific services only
./deploy.sh --only service1,service2

# Deploy all except specified services
./deploy.sh --exclude service1,service2

# Show help
./deploy.sh --help
```

### Deployment Flow

1. Check prerequisites (yq, config file, kubectl context)
2. Parse command line arguments
3. Deploy dependencies first:
   - Create namespaces
   - Generate manifests
   - Apply to Kubernetes
   - Wait for pods to be ready (120s timeout)
4. Create ConfigMaps
5. Process APIs:
   - Check directory and Dockerfile
   - Build Docker image
   - Generate manifest
   - Deploy to Kubernetes
6. Wait for all deployments to be ready
7. Show final status

## Kubernetes Manifests

### Generated Manifest Structure

#### For APIs (Custom Applications)
- **Deployment**: Single replica, `imagePullPolicy: Never`
- **Service**: Type `LoadBalancer` for easy local access
- **Environment Variables**: Injected from YAML config
- **ConfigMap Volumes**: Mounted as needed

#### For Dependencies (Infrastructure)
- **PersistentVolumeClaim**: 1Gi storage for stateful services
- **Deployment**: Single replica, `imagePullPolicy: IfNotPresent`
- **Service**: Type `ClusterIP` for internal communication
- **Health Probes**: TCP socket readiness and liveness checks
- **ConfigMap Volumes**: For configuration files (e.g., Prometheus)

### Service Discovery

All services communicate via Kubernetes DNS:
- Format: `<service-name>:<port>`
- Example: `http://operational-api:8080`
- Example: `http://prometheus:19090`

## Environment Variable Management

Environment variables are stored in `config/local-k8s-env.yml` with the following structure:

```yaml
service-name:
  VARIABLE_NAME: "value"
  ANOTHER_VAR: "another value"
```

The deploy script reads these variables and injects them into the generated Kubernetes manifests.

### Critical Environment Variable Consistency

Environment variables must be consistent across services. When a service's port or hostname changes, all services that connect to it must have their environment variables updated.

**Example Dependencies**:
- If `operational-api` port changes, update `OPERATIONAL_API_URL` in `management-plane-api` and `core-ui`
- All services using Prometheus must use `PROMETHEUS_URL=http://prometheus:19090`

## ConfigMap Usage

ConfigMaps provide file-based configuration:

1. **authentik-groups-config**
   - Source: `../tenant-auth-management-api/example-authentik-groups-file.yml`
   - Target: `tenant-auth-management-api` at `/app/example-authentik-groups-file.yml`

2. **prometheus-config**
   - Source: `config/prometheus-config.yml`
   - Target: `prometheus` at `/etc/prometheus/prometheus.yml`

3. **openexchangerates-credentials**
   - Source: `mocks/openexchangerates-mock/secrets/credentials.json`
   - Target: `operational-api` at `/secrets/openexchangerates/credentials.json`

## Mock Services Details

### OpenExchangeRates Mock

**Purpose**: Simulate external currency exchange rate API

**Implementation**:
- Flask HTTP server on port 8080
- Endpoint: `/api/latest.json`
- Returns 20 currency pairs with USD base
- Each request adds ±2% random variation to simulate market changes
- Does not validate API keys (accepts any value)

**Base Currencies**:
AED, AUD, CAD, CHF, CNY, EUR, GBP, HKD, INR, JPY, KRW, MXN, NOK, NZD, RUB, SEK, SGD, TRY, USD, ZAR

### Prometheus Data Generator

**Purpose**: Generate synthetic network traffic metrics for testing

**Implementation**:
- Python script using `prometheus_client` library
- Pushes metrics to Pushgateway every 15 seconds
- Generates multiple metric types with realistic labels

**Metrics Generated**:
- `sum:cnstraffic_interface_rx_bytes:rate5m` - 5-minute traffic rate
- `sum:cnstraffic_interface_rx_bytes:rate1h` - 1-hour traffic rate
- `sum:cnstraffic_interface_rx_bytes:rate1d` - 1-day traffic rate
- `active_connections_total` - Connection count
- `packet_loss_rate_percent` - Packet loss percentage

**Label Dimensions**:
- Tenants: `patmon`, `perimara`, `demo-tenant`
- Providers: `AWS`, `GCP`, `Azure`, `Cloudflare`, `Akamai`, `DigitalOcean`
- Connection Types: `Direct`, `Transit`, `Peering`, `VPN`
- Interfaces: `eth0`, `eth1`, `eth2`

**Traffic Simulation**:
- Random rates between 1MB/s and 100MB/s
- 30% probability of skipping provider/connection combinations
- Realistic smoothing between time windows (5m → 1h → 1d)

## Prometheus Configuration

Prometheus scrapes the following targets:

1. **prometheus** (localhost:19090) - Self-monitoring
2. **pushgateway** (pushgateway:19091) - Synthetic metrics with `honor_labels: true`
3. **operational-api** (operational-api:8080) - If it exposes metrics endpoint
4. **management-plane-api** (management-plane-api:8000) - If it exposes metrics endpoint

Scrape interval: 15 seconds
Evaluation interval: 15 seconds

## Storage and Persistence

### Persistent Volumes
- Uses Docker Desktop's default storage class
- PersistentVolumeClaims with `ReadWriteOnce` access mode
- 1Gi storage allocation per stateful service
- Data persists across pod restarts but not across `kubectl delete pvc`

### Stateful Services
- **etcd**: `/etcd-data`
- **valkey**: `/data`
- **prometheus**: `/prometheus`

## Development Workflow

### Full Stack Deployment
```bash
./deploy.sh
```

### Backend-Only Deployment (for UI hot reload)
```bash
# Deploy all except frontend
./deploy.sh --exclude core-ui

# In separate terminal, run UI locally
cd ../core-ui
npm run dev
```

### Single Service Update
```bash
# Delete existing deployment to force new image
kubectl delete deployment operational-api

# Rebuild and redeploy
./deploy.sh --only operational-api
```

### Debugging Commands
```bash
# Check pod status
kubectl get pods

# View logs
kubectl logs <pod-name>
kubectl logs -f <pod-name>                    # Follow logs
kubectl logs -f -l app=<app-name>             # Follow by label

# Port forward for internal services
kubectl port-forward service/prometheus 19090:19090

# Restart a service
kubectl rollout restart deployment/<service-name>
```

### Complete Cleanup
```bash
kubectl delete deployment --all
kubectl delete service --all
kubectl delete pvc --all
kubectl delete configmap --all
```

## Prerequisites

### Required Software
- **Docker Desktop** with Kubernetes enabled
- **kubectl** configured for `docker-desktop` context
- **yq** (YAML processor) version 4.x

### Installation (WSL/Linux)
```bash
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

## Security Considerations

### Local Development Only
This project is designed for local development and testing. It is not production-ready and includes several security shortcuts:

1. **No TLS/HTTPS** - All communication is unencrypted HTTP
2. **LoadBalancer Services** - APIs exposed directly for easy access
3. **Dummy Credentials** - Mock services use hardcoded dummy credentials
4. **No Resource Limits** - No CPU/memory limits on containers
5. **No Network Policies** - All pods can communicate freely
6. **External Authentik** - Requires real authentication service with credentials in plaintext config

### Credential Management
- Real credentials stored in `config/local-k8s-env.yml` (gitignored)
- Dummy credentials in mock services tracked in Git (intentional for local dev)
- Authentik credentials must be obtained from real instance

## Adding New Services

### Adding a New API
1. Add entry to `APIS` array in `deploy.sh`:
   ```bash
   ["new-api"]="../new-api:new-api-image:8888:default"
   ```
2. Add environment variables to `config/local-k8s-env.yml`:
   ```yaml
   new-api:
     PORT: "8888"
     OTHER_VAR: "value"
   ```
3. Ensure Dockerfile exists in `../new-api/`
4. Run `./deploy.sh`

### Adding a New Dependency
1. Add entry to `DEPENDENCIES` array in `deploy.sh`:
   ```bash
   ["new-dep"]="image:name:tag:container-port:service-port:default"
   ```
2. Add environment variables if needed
3. Run `./deploy.sh`

### Adding a ConfigMap
1. Add entry to `CONFIGMAPS` array in `deploy.sh`:
   ```bash
   ["config-name"]="default:path/to/file.yml:/mount/path:target-service"
   ```
2. Ensure source file exists
3. Run `./deploy.sh`

## Troubleshooting

### Common Issues

**Issue**: Pods stuck in `ImagePullBackOff`
- **Cause**: Docker image not built or wrong imagePullPolicy
- **Solution**: Rebuild image with `./deploy.sh --only <service>`

**Issue**: Pods in `CrashLoopBackOff`
- **Cause**: Application errors, missing dependencies, wrong env vars
- **Solution**: Check logs with `kubectl logs <pod-name>`

**Issue**: Services can't connect to each other
- **Cause**: Wrong service names in environment variables
- **Solution**: Verify service DNS names match Kubernetes service names

**Issue**: Changes not reflected after rebuild
- **Cause**: Kubernetes using cached image
- **Solution**: Delete deployment first: `kubectl delete deployment <name>`

**Issue**: yq command not found
- **Cause**: yq not installed
- **Solution**: Follow yq installation instructions in Prerequisites

## Performance Characteristics

### Resource Usage (Typical)
- **Total Containers**: 11 (5 APIs + 4 dependencies + 2 mocks)
- **Memory**: ~4-6GB total (depends on API implementations)
- **CPU**: Minimal during idle, spikes during builds
- **Storage**: ~1-2GB for images, ~3GB for persistent volumes

### Build Times (Approximate)
- **First build**: 5-10 minutes (all images from scratch)
- **Incremental rebuild**: 30-60 seconds per service
- **Full deployment**: 2-3 minutes (with image building)

### Startup Times
- **Dependencies ready**: ~30 seconds
- **APIs ready**: ~1-2 minutes (after dependencies)
- **Total stack ready**: ~2-3 minutes from `./deploy.sh`

## Limitations

1. **No Alloy Agents Deployed** - ZTAC IP reputation engine is deployed but non-functional without Grafana Alloy agents to collect and send authentication logs. The IP blocking functionality requires Alloy agents as sidecars or DaemonSets.
2. **Single Replica Only** - No high availability or load balancing
3. **No Secrets Management** - Credentials in plaintext YAML files
4. **No Ingress Controller** - Services accessed via LoadBalancer IPs
5. **No Monitoring/Alerting** - Beyond basic Prometheus metrics
6. **No CI/CD Integration** - Manual deployment only
7. **No Multi-Tenancy** - All services in default namespace
8. **Docker Desktop Requirement** - Not compatible with other K8s distributions
9. **Mock Data Only** - Not suitable for realistic load testing

## Future Enhancements

Potential improvements for this deployment tool:

1. **Grafana Alloy Agents** - Deploy Alloy as DaemonSet or sidecars to collect authentication logs and enable full ZTAC IP reputation functionality. Configure OTLP exporters to send logs to `ztac-ip-reputation-engine-service:4317`.
2. **Helm Charts** - Migrate to Helm for better templating
3. **Skaffold Integration** - Automated rebuild and redeploy on file changes
4. **Tilt Configuration** - Enhanced local development experience
5. **Resource Limits** - CPU/memory limits for stability
6. **Health Check Endpoints** - HTTP health probes instead of TCP
7. **Init Containers** - Dependency waiting logic
8. **Multi-Environment Support** - Dev, staging, test configurations
9. **Secret Management** - Kubernetes Secrets or external secret managers
10. **Service Mesh** - Istio or Linkerd for observability
11. **GitOps** - ArgoCD or Flux for declarative deployment

## Technical Decisions

### Why Bash Script?
- Simple, no runtime dependencies beyond standard tools
- Easy to understand and modify
- Direct kubectl and docker CLI access
- Suitable for local development automation

### Why Generate Manifests?
- Dynamic environment variable injection
- Single source of truth for configuration
- Easier than maintaining multiple YAML files
- Allows programmatic manifest customization

### Why LoadBalancer Services for APIs?
- Easy access from host machine without port-forwarding
- Simulates production-like external access
- Docker Desktop LoadBalancer creates localhost mappings

### Why Mock Services?
- No external API dependencies during development
- Predictable, deterministic test data
- Faster development cycles
- No API rate limits or costs

## Version Compatibility

### Tested Versions
- **Docker Desktop**: 4.x with Kubernetes 1.27+
- **kubectl**: 1.27+
- **yq**: 4.x
- **Python** (for mocks): 3.11+
- **Base Images**:
  - etcd: v3.5.9
  - valkey: 7.2-alpine
  - prometheus: latest
  - pushgateway: latest

### Known Issues
- **yq v3.x**: Not compatible (different syntax)
- **Kubernetes < 1.24**: May have API version compatibility issues
- **Docker Desktop with WSL2**: Requires WSL2 integration enabled

## Access Points

After successful deployment:

### User-Facing Services
- **Core UI**: http://localhost:3000 (if deployed in cluster)
- **Core UI**: http://dev.core-ui.local:3000/ (custom host entry may be needed)

### Internal Services (port-forward required)
```bash
# Prometheus
kubectl port-forward service/prometheus 19090:19090
# Access at: http://localhost:19090

# Pushgateway
kubectl port-forward service/pushgateway 19091:19091
# Access at: http://localhost:19091

# Operational API
kubectl port-forward service/operational-api 8080:8080
# Access at: http://localhost:8080
```

### Service URLs (internal to cluster)
- management-plane-api: http://management-plane-api:8000
- operational-api: http://operational-api:8080
- tenant-auth-management-api: http://tenant-auth-management-api:8082
- ztac-ip-reputation-engine-service:
  - gRPC API: ztac-ip-reputation-engine-service:9090
  - OTLP receiver: ztac-ip-reputation-engine-service:4317
  - Metrics: http://ztac-ip-reputation-engine-service:8080
- etcd: etcd:2379
- valkey: valkey:6379
- prometheus: http://prometheus:19090
- pushgateway: http://pushgateway:19091
- openexchangerates-mock: http://openexchangerates-mock:8080

## Maintenance

### Regular Tasks
- **Update base images**: Periodically update dependency image tags
- **Clean up volumes**: `kubectl delete pvc --all` when storage accumulates
- **Rebuild images**: After dependency changes in APIs
- **Update env vars**: When service endpoints or credentials change

### Monitoring Health
```bash
# Check all pods
kubectl get pods

# Check persistent volume usage
kubectl get pvc

# Check service endpoints
kubectl get endpoints

# View deployment status
kubectl get deployments
```
