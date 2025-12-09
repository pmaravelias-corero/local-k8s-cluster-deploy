# Local Kubernetes Cluster Deployment

Tooling for deploying all APIs and dependencies to a local Kubernetes cluster (Docker Desktop) for development and testing.
The directory of this project is expected to be in the same directory as all the other APIs, as it will build all the Docker
images from the corresponding Dockerfiles.
If any API exists in a different location, update the `APIS` array in `deploy.sh` with the relative path to that location.

Example sructure:
```
~/Projects/
├── core-ui
├── local-k8s-cluster-deploy           # This project
├── management-plane-api
├── operational-api
├── tenant-auth-management-api
├── ztac-ip-reputation-engine-service
```

## Important Notes:

### Environment Variable Consistency

Environment variables must be kept consistent across the stack. Changing a service's port or hostname requires updating the corresponding URLs in any services that connect to it.

Example: Changing `operational-api`'s port requires updating `OPERATIONAL_API_URL` in both `management-plane-api` and `core-ui`.

### External Dependencies

**Authentik:** This stack requires a real Authentik instance for authentication. Update the following variables in `config/local-k8s-env.yml` to point to your Authentik server:

- `AUTHENTIK_URL`
- `AUTHENTIK_ISSUER`
- `JWKS_URL`
- `AUTHENTIK_CLIENT_ID`
- `AUTHENTIK_CLIENT_SECRET`

The mock services (OpenExchangeRates, Prometheus data) are local, but authentication is handled by an external Authentik instance.

## Prerequisites

- Docker Desktop with Kubernetes enabled
- `kubectl` configured for `docker-desktop` context
- `yq` installed (YAML processor)

### Install yq (on WSL/Linux)
```bash
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

## Quick Start

The project comes pre-configured with environment variables that can successfully deploy all the APIs locally as a Kubernetes
cluster, so that they successfully communicate with each other

### Deployment

#### Full deployment (all services):
```bash
./deploy.sh
```

#### Selective deployment (specific services only):

**Deploy only specified services:**

**Important:** Delete the existing deployment first to force using the newly built image

**Examples:**
```bash
# Deploy single service
kubectl delete deployment core-ui
./deploy.sh --only core-ui

# Deploy multiple services
kubectl delete deployment operational-api valkey prometheus
./deploy.sh --only operational-api,valkey,prometheus

# Deploy service with dependencies
kubectl delete deployment management-plane-api etcd
./deploy.sh --only management-plane-api,etcd
```

**Note:** Dependencies are not automatically included - specify them explicitly if needed.

---

**Deploy all services except some:**

Useful for running services locally with hot reload:
```bash
# Deploy everything except core-ui
./deploy.sh --exclude core-ui

# Exclude multiple services
./deploy.sh --exclude core-ui,prometheus-data-generator
```

**Recommended:** Run Core UI locally for development with hot reload:
```bash
# Deploy all backend services
./deploy.sh --exclude core-ui

# Run UI locally in a separate terminal
cd ../core-ui
npm run dev
```

Your UI will run on `http://localhost:3000` with hot reload while connecting to the Kubernetes backend services.

### Access services
   - Core UI: http://localhost:3000
   - Prometheus:
	   - Forward your local port to the local Kubernetes cluster port `kubectl port-forward service/prometheus 19090:19090`
		- Access Prometheus on http://localhost:19090

## Project Structure
```
local-k8s-cluster-deploy/
├── deploy.sh                    # Main deployment script
├── config/
│   ├── local-k8s-env.yml        # Environment variables (gitignored)
│   ├── local-k8s-env.yml.example # Template
│   └── prometheus-config.yml    # Prometheus scrape config
├── mocks/
│   ├── openexchangerates-mock/  # Mock currency exchange API
│   └── prometheus-data-generator/ # Generates synthetic metrics
├── secrets/                     # Kubernetes secrets
└── manifests/                   # Generated K8s manifests (gitignored)
```

## Configuration

### Dependencies

- **etcd** - Key-value store (Port 2379)
- **valkey** - Redis-compatible cache (Port 6379)
- **prometheus** - Metrics database (Port 19090)
- **pushgateway** - Prometheus push endpoint (Port 19091)
- **openexchangerates-mock** - Mock currency API (Port 8080)
- **prometheus-data-generator** - Synthetic metrics

## Troubleshooting

**Check pod status:**
```bash
kubectl get pods
```

**View logs:**
```bash
kubectl logs <pod-name>
kubectl logs -f <pod-name>        # Follow logs for a pod
kubectl logs -f -l app=<app-name> # Follow logs for an app, using the app selector - sometimes pod names have randomly generated names
```

**Restart a service:**
```bash
kubectl rollout restart deployment/<service-name>
```

**Clean up everything:**
```bash
kubectl delete deployment --all
kubectl delete service --all
kubectl delete pvc --all
kubectl delete configmap --all
```

## Mock Services

### OpenExchangeRates Mock

Returns realistic currency exchange rate data for ~20 currencies.

The `credentials.json` file in `mocks/openexchangerates-mock/secrets/` is intentionally tracked in Git. It contains a dummy
API key that allows the operational-api to load credentials in production format, but the mock service doesn't validate it.

- **Endpoint:** `http://openexchangerates-mock:8080/api/latest.json`
- **Rates update:** Every request has ±2% variation to simulate market changes

### Prometheus Data Generator

Generates synthetic metrics matching production queries:
- Network traffic metrics (`cnstraffic_interface_rx_bytes`)
- Provider and connection type labels
- Multiple tenants and interfaces

## Development

**Add a new API:**

1. Add to `APIS` array in `deploy.sh`
2. Add environment variables to `config/local-k8s-env.yml`
3. Run `./deploy.sh`

**Add a new dependency:**

1. Add to `DEPENDENCIES` array in `deploy.sh`
2. Add any required environment variables
3. Run `./deploy.sh`

## Notes

- This is for **local development only**
- Services use LoadBalancer type for easy access
- Data persists in PersistentVolumeClaims
- Mock services don't require real credentials, but files might need to exist so that the services can read them
