#!/bin/bash

# Kubernetes Multi-API Deploy Script.
# Used to deploy APIs in a local Kubernetes cluster (e.g. in Docker Desktop).

set -e  # Exit on any error

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo "Error: yq is required but not installed."
    echo "Install it (on WSL) with:"
		echo "   sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
		echo "   sudo chmod +x /usr/local/bin/yq"
    exit 1
fi

if [ ! -f "config/local-k8s-env.yml" ]; then
    echo "Error: config/local-k8s-env.yml not found"
    exit 1
fi

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - Add your APIs here
declare -A APIS=(
    # Format: ["api-name"]="directory:image-name:ports:namespace"
    # ports can be: single port (8080) or comma-separated (4317,9090,8080)

		# Real APIs (in parent directory)
    ["management-plane-api"]="../management-plane-api:management-plane-api:8000,8080:default"
    ["operational-api"]="../operational-api:operational-api:8080:default"
    ["tenant-auth-management-api"]="../tenant-auth-management-api:tenant-auth-management-api:8082,9090:default"
    ["ztac-ip-reputation-engine-service"]="../ztac-ip-reputation-engine-service:ztac-ip-reputation-engine-service:4317,9090,8080:default"
    ["core-ui"]="../core-ui:core-ui:3000:default"

		# Mock services (in this project)
    ["prometheus-data-generator"]="mocks/prometheus-data-generator:prometheus-data-generator:12345:default"
    ["openexchangerates-mock"]="mocks/openexchangerates-mock:openexchangerates-mock:8080:default"
    ["auth-log-generator"]="mocks/auth-log-generator:auth-log-generator:12346:default"
)

# Configuration - Add dependency services here
declare -A DEPENDENCIES=(
    # Format: ["service-name"]="image:container-port:service-port:namespace"
    # container-port: what the app listens on inside the container
    # service-port: what port to expose via the Kubernetes service
    ["etcd"]="quay.io/coreos/etcd:v3.5.9:2379:2379:default"
    ["valkey"]="valkey/valkey:7.2-alpine:6379:6379:default"
    ["prometheus"]="prom/prometheus:latest:9090:19090:default"
    ["pushgateway"]="prom/pushgateway:latest:9091:19091:default"
    ["alloy"]="grafana/alloy:latest:12345:12345:default"
    ["loki"]="grafana/loki:latest:3100:3100:default"
)

declare -A CONFIGMAPS=(
		["authentik-groups-config"]="default:../tenant-auth-management-api/example-authentik-groups-file.yml:/app/example-authentik-groups-file.yml:tenant-auth-management-api"
		["prometheus-config"]="default:config/prometheus-config.yml:/etc/prometheus/prometheus.yml:prometheus"
		["openexchangerates-credentials"]="default:mocks/openexchangerates-mock/secrets/credentials.json:/secrets/openexchangerates/credentials.json:operational-api"
		["alloy-config"]="default:config/alloy/config.alloy:/etc/alloy/config.alloy:alloy"
)


# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to check if directory exists
check_directory() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        print_error "Directory $dir does not exist"
        return 1
    fi
    return 0
}

# Function to check if Dockerfile exists
check_dockerfile() {
    local dir=$1
    if [ ! -f "$dir/Dockerfile" ]; then
        print_error "Dockerfile not found in $dir"
        return 1
    fi
    return 0
}

# Function to build Docker image
build_image() {
    local dir=$1
    local image_name=$2

    print_info "Building image $image_name from $dir..."

    cd "$dir"
    docker build -t "$image_name:latest" .
    cd - > /dev/null

    print_info "Successfully built $image_name:latest"
}

# Function to create namespace if it doesn't exist
create_namespace() {
    local namespace=$1

    if [ "$namespace" != "default" ]; then
        if ! kubectl get namespace "$namespace" &> /dev/null; then
            print_info "Creating namespace $namespace..."
            kubectl create namespace "$namespace"
        fi
    fi
}

# Function to create ConfigMap from file
create_configmap() {
    local configmap_name=$1
    local namespace=$2
    local source_file=$3
    
    if [ ! -f "$source_file" ]; then
        print_error "Source file $source_file not found for ConfigMap $configmap_name"
        return 1
    fi
    
    print_info "Creating ConfigMap $configmap_name from $source_file..."
    
    # Get the filename for the key in the ConfigMap
    local filename=$(basename "$source_file")
    
    # Delete existing ConfigMap if it exists
    kubectl delete configmap "$configmap_name" -n "$namespace" 2>/dev/null || true
    
    # Create ConfigMap
    kubectl create configmap "$configmap_name" \
        --from-file="$filename=$source_file" \
        -n "$namespace"
    
    print_info "ConfigMap $configmap_name created successfully"
}

# Function to read env vars from YAML config for a service
read_env_vars_from_yaml() {
    local service_name=$1

    local env_yaml=""

    # First, check if global configuration exists and add it for specific services
    # Services that need global tenant configuration
    if [[ "$service_name" == "auth-log-generator" || "$service_name" == "prometheus-data-generator" || "$service_name" == "alloy" ]]; then
        if yq eval "has(\"global\")" config/local-k8s-env.yml | grep -q "true"; then
            local global_keys=$(yq eval ".global | keys | .[]" config/local-k8s-env.yml)

            while IFS= read -r key; do
                if [ -n "$key" ]; then
                    local value=$(yq eval ".global.$key" config/local-k8s-env.yml)

                    # Escape special characters for YAML
                    value=$(echo "$value" | sed 's/"/\\"/g')

                    env_yaml="${env_yaml}        - name: $key
          value: \"$value\"
"
                fi
            done <<< "$global_keys"
        fi
    fi

    # Check if service exists in YAML
    if ! yq eval "has(\"$service_name\")" config/local-k8s-env.yml | grep -q "true"; then
        if [ -z "$env_yaml" ]; then
            print_warn "No environment variables found for $service_name in local-k8s-env.yml"
        fi
        echo -n "$env_yaml"
        return
    fi

    # Read all key-value pairs for this service
    local keys=$(yq eval ".$service_name | keys | .[]" config/local-k8s-env.yml)

    while IFS= read -r key; do
        if [ -n "$key" ]; then
            local value=$(yq eval ".$service_name.$key" config/local-k8s-env.yml)

            # Escape special characters for YAML
            value=$(echo "$value" | sed 's/"/\\"/g')

            env_yaml="${env_yaml}        - name: $key
          value: \"$value\"
"
        fi
    done <<< "$keys"

    echo -n "$env_yaml"
}

# Function to generate manifests for dependency services
generate_dependency_manifest() {
    local service_name=$1
    local image=$2
    local container_port=$3
    local service_port=$4
    local namespace=$5

    local manifest_file="manifests/${service_name}.yaml"

    print_info "Generating manifest for dependency: $service_name..."

    # Read environment variables from YAML config
    local env_vars=$(read_env_vars_from_yaml "$service_name")

    if [ -z "$env_vars" ]; then
        env_vars="        # No environment variables configured"
    fi

    # Create a persistent volume claim for stateful services
    local volume_section=""
    if [[ "$service_name" == *"etcd"* ]] || [[ "$service_name" == *"postgres"* ]] || [[ "$service_name" == *"mysql"* ]] || [[ "$service_name" == *"mongo"* ]] || [[ "$service_name" == *"valkey"* ]] || [[ "$service_name" == *"redis"* ]] || [[ "$service_name" == *"prometheus"* ]]; then
        local mount_path="/etcd-data"
        if [[ "$service_name" == *"valkey"* ]] || [[ "$service_name" == *"redis"* ]]; then
            mount_path="/data"
        elif [[ "$service_name" == *"prometheus"* ]]; then
            mount_path="/prometheus"
        fi
        volume_section="        volumeMounts:
        - name: ${service_name}-data
          mountPath: $mount_path
      volumes:
      - name: ${service_name}-data
        persistentVolumeClaim:
          claimName: ${service_name}-pvc"
    fi

    # Add ConfigMap volume mount if this dependency needs it
    local configmap_volume=""
    for cm_name in "${!CONFIGMAPS[@]}"; do
        IFS=':' read -r cm_namespace source_file mount_path target_service <<< "${CONFIGMAPS[$cm_name]}"

        if [ "$target_service" == "$service_name" ]; then
            local filename=$(basename "$source_file")
            if [ -n "$volume_section" ]; then
                # Already have volumes, add to volumeMounts
                volume_section=$(echo "$volume_section" | sed "s|volumeMounts:|volumeMounts:\n        - name: ${cm_name}\n          mountPath: ${mount_path}\n          subPath: ${filename}|")
                volume_section=$(echo "$volume_section" | sed "s|volumes:|volumes:\n      - name: ${cm_name}\n        configMap:\n          name: ${cm_name}|")
            else
                configmap_volume="        volumeMounts:
        - name: ${cm_name}
          mountPath: ${mount_path}
          subPath: ${filename}
      volumes:
      - name: ${cm_name}
        configMap:
          name: ${cm_name}"
            fi
        fi
    done

    # Special handling for Alloy (needs RBAC for Kubernetes API access)
    if [ "$service_name" == "alloy" ]; then
        cat > "$manifest_file" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alloy
  namespace: $namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: alloy
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/proxy
      - services
      - endpoints
      - pods
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources:
      - pods/log
    verbs: ["get", "list"]
  - nonResourceURLs:
      - /metrics
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: alloy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: alloy
subjects:
  - kind: ServiceAccount
    name: alloy
    namespace: $namespace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $service_name
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $service_name
  template:
    metadata:
      labels:
        app: $service_name
    spec:
      serviceAccountName: alloy
      containers:
      - name: $service_name
        image: $image
        imagePullPolicy: IfNotPresent
        args:
          - "run"
          - "/etc/alloy/config.alloy"
          - "--server.http.listen-addr=0.0.0.0:12345"
          - "--storage.path=/var/lib/alloy/data"
        ports:
        - containerPort: $container_port
          name: http-metrics
        env:
$env_vars
$configmap_volume
---
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $namespace
spec:
  type: ClusterIP
  selector:
    app: $service_name
  ports:
  - port: ${service_port}
    targetPort: ${container_port}
    protocol: TCP
    name: http-metrics
EOF
        print_info "Alloy manifest with RBAC saved to $manifest_file"
        return 0
    fi

    cat > "$manifest_file" << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${service_name}-pvc
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $service_name
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $service_name
  template:
    metadata:
      labels:
        app: $service_name
    spec:
      containers:
      - name: $service_name
        image: $image
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: $container_port
        env:
$env_vars
        readinessProbe:
          tcpSocket:
            port: $container_port
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: $container_port
          initialDelaySeconds: 15
          periodSeconds: 20
$volume_section
$configmap_volume
---
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $namespace
spec:
  type: ClusterIP
  selector:
    app: $service_name
  ports:
  - port: ${service_port}
    targetPort: ${container_port}
    protocol: TCP
EOF

    print_info "Dependency manifest saved to $manifest_file"
}

# Function to generate Kubernetes manifests for APIs
generate_manifests() {
    local api_name=$1
    local image_name=$2
    local ports=$3
    local namespace=$4

		local manifest_file="manifests/${api_name}.yaml"

    mkdir -p manifests

    print_info "Generating manifest for $api_name..."

    # Read environment variables from YAML config
    local env_vars=$(read_env_vars_from_yaml "$api_name")

    if [ -z "$env_vars" ]; then
        env_vars="        # No environment variables configured"
    fi

    # Check if this API needs ConfigMap volumes
    local volume_mounts=""
    local volumes=""

    for cm_name in "${!CONFIGMAPS[@]}"; do
        IFS=':' read -r cm_namespace source_file mount_path target_api <<< "${CONFIGMAPS[$cm_name]}"

        if [ "$target_api" == "$api_name" ]; then
            local filename=$(basename "$source_file")
            volume_mounts="${volume_mounts}        volumeMounts:
        - name: ${cm_name}
          mountPath: ${mount_path}
          subPath: ${filename}
"
            volumes="${volumes}      volumes:
      - name: ${cm_name}
        configMap:
          name: ${cm_name}
"
        fi
    done

    # Parse ports (can be single or comma-separated)
    IFS=',' read -ra PORT_ARRAY <<< "$ports"

    # Generate container ports section
    local container_ports=""
    local service_ports=""
    local port_names=("http" "grpc" "metrics" "otlp" "admin" "api")

    for i in "${!PORT_ARRAY[@]}"; do
        local port="${PORT_ARRAY[$i]}"
        local port_name="${port_names[$i]}"

        # Use descriptive names for known ports
        if [ "$port" == "4317" ]; then
            port_name="otlp"
        elif [ "$port" == "9090" ] && [ "$api_name" == "ztac-ip-reputation-engine-service" ]; then
            port_name="grpc-api"
        elif [ "$port" == "9090" ] && [ "$api_name" == "tenant-auth-management-api" ]; then
            port_name="metrics"
        elif [ "$port" == "8080" ] && [ "$api_name" == "ztac-ip-reputation-engine-service" ]; then
            port_name="metrics"
        elif [ "$port" == "8080" ] && [ "$api_name" == "management-plane-api" ]; then
            port_name="metrics"
        elif [ "$port" == "8080" ]; then
            port_name="http"
        elif [ "$port" == "8000" ]; then
            port_name="http"
        elif [ "$port" == "8082" ]; then
            port_name="http"
        elif [ "$port" == "3000" ]; then
            port_name="http"
        fi

        # For multiple ports, ALL need names. For single port, name is optional
        if [ ${#PORT_ARRAY[@]} -gt 1 ]; then
            # Multiple ports - all need names
            if [ $i -eq 0 ]; then
                container_ports="        - containerPort: $port
          name: $port_name"
                service_ports="  - name: $port_name
    port: $port
    targetPort: $port
    protocol: TCP"
            else
                container_ports="$container_ports
        - containerPort: $port
          name: $port_name"
                service_ports="$service_ports
  - name: $port_name
    port: $port
    targetPort: $port
    protocol: TCP"
            fi
        else
            # Single port - no name needed
            container_ports="        - containerPort: $port"
            service_ports="  - port: $port
    targetPort: $port
    protocol: TCP"
        fi
    done

    cat > "$manifest_file" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $api_name
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $api_name
  template:
    metadata:
      labels:
        app: $api_name
    spec:
      containers:
      - name: $api_name
        image: $image_name:latest
        imagePullPolicy: Never
        ports:
$container_ports
        env:
$env_vars
$volume_mounts
$volumes
---
apiVersion: v1
kind: Service
metadata:
  name: $api_name
  namespace: $namespace
spec:
  type: LoadBalancer
  selector:
    app: $api_name
  ports:
$service_ports
EOF

    print_info "Manifest saved to $manifest_file"
}

# Function to check if a service should be deployed
should_deploy() {
    local service_name=$1
    
    # Check exclude filter first
    if [ -n "$exclude_filter" ]; then
        if echo "$exclude_filter" | grep -q "\b$service_name\b"; then
            return 1  # Service is excluded
        fi
        return 0  # Service not excluded, deploy it
    fi
    
    # Check include filter
    if [ -n "$deploy_filter" ]; then
        if echo "$deploy_filter" | grep -q "\b$service_name\b"; then
            return 0  # Service is included
        fi
        return 1  # Service not included
    fi
    
    # No filters specified, deploy everything
    return 0
}

# Function to deploy to Kubernetes
deploy_to_k8s() {
    local api_name=$1
    local manifest_file="manifests/${api_name}.yaml"

    print_info "Deploying $api_name to Kubernetes..."
    kubectl apply -f "$manifest_file"
    print_info "Successfully deployed $api_name"
}

# Function to show status
show_status() {
    print_info "Current deployment status:"
    echo ""
    kubectl get deployments --all-namespaces
    echo ""
    kubectl get pods --all-namespaces
    echo ""
    kubectl get services --all-namespaces
}

# Main execution
main() {
    local deploy_filter=""
    local exclude_filter=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --only)
                deploy_filter="$2"
                shift 2
                ;;
            --exclude)
                exclude_filter="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--only service1,service2,...] [--exclude service1,service2,...]"
                echo ""
                echo "Options:"
                echo "  --only <services>      Deploy only specified services (comma-separated)"
                echo "                         Example: --only operational-api,etcd,prometheus"
                echo ""
                echo "  --exclude <services>   Deploy all services except specified ones (comma-separated)"
                echo "                         Example: --exclude core-ui,prometheus-data-generator"
                echo ""
                echo "  --help, -h            Show this help message"
                echo ""
                echo "Note: --only and --exclude cannot be used together."
                echo "Without any flags, all services are deployed."
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Run '$0 --help' for usage information"
                exit 1
                ;;
        esac
    done

    # Validate that --only and --exclude aren't used together
    if [ -n "$deploy_filter" ] && [ -n "$exclude_filter" ]; then
        print_error "Cannot use --only and --exclude together"
        exit 1
    fi

    print_info "Starting Kubernetes deployment process..."
    echo ""

    # Check if kubectl is configured for docker-desktop
    current_context=$(kubectl config current-context)
    if [ "$current_context" != "docker-desktop" ]; then
        print_warn "Current context is $current_context, not docker-desktop"
        read -p "Switch to docker-desktop context? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl config use-context docker-desktop
        else
            print_error "Aborting. Please switch to docker-desktop context manually."
            exit 1
        fi
    fi

    # Create ConfigMaps FIRST (before dependencies that need them)
    if [ ${#CONFIGMAPS[@]} -gt 0 ]; then
        print_info "Creating ConfigMaps..."
        echo ""

        for cm_name in "${!CONFIGMAPS[@]}"; do
            IFS=':' read -r namespace source_file mount_path target_api <<< "${CONFIGMAPS[$cm_name]}"

            # Check if the target service is being deployed
            if ! should_deploy "$target_api"; then
                print_info "Skipping ConfigMap $cm_name (target $target_api not in filter)"
                continue
            fi

            print_info "Processing ConfigMap: $cm_name for $target_api..."

            create_namespace "$namespace" || continue
            create_configmap "$cm_name" "$namespace" "$source_file" || continue
        done

        echo ""
        print_info "Waiting for ConfigMaps to be ready..."
        sleep 2

        # Verify ConfigMaps were created
        for cm_name in "${!CONFIGMAPS[@]}"; do
            IFS=':' read -r namespace source_file mount_path target_api <<< "${CONFIGMAPS[$cm_name]}"
            if should_deploy "$target_api"; then
                if kubectl get configmap "$cm_name" -n "$namespace" &> /dev/null; then
                    print_info "✓ ConfigMap $cm_name is ready"
                else
                    print_warn "ConfigMap $cm_name not found"
                fi
            fi
        done

        echo ""
    fi

    # Deploy dependencies after ConfigMaps are ready
    if [ ${#DEPENDENCIES[@]} -gt 0 ]; then
        print_info "Deploying dependencies..."
        echo ""

        for service_name in "${!DEPENDENCIES[@]}"; do
            # Check if we should deploy this dependency
            if ! should_deploy "$service_name"; then
                print_info "Skipping $service_name (not in filter)"
                continue
            fi

            local dep_config="${DEPENDENCIES[$service_name]}"

            # Parse config: image:container-port:service-port:namespace
            local namespace=$(echo "$dep_config" | rev | cut -d':' -f1 | rev | xargs)
            local service_port=$(echo "$dep_config" | rev | cut -d':' -f2 | rev | xargs)
            local container_port=$(echo "$dep_config" | rev | cut -d':' -f3 | rev | xargs)
            local image=$(echo "$dep_config" | rev | cut -d':' -f4- | rev | xargs)

            print_info "Processing dependency: $service_name..."
            print_info "  Container port: $container_port, Service port: $service_port"

            create_namespace "$namespace" || continue
						generate_dependency_manifest "$service_name" "$image" "$container_port" "$service_port" "$namespace" || continue
            deploy_to_k8s "$service_name" || continue
        done

        echo ""
        print_info "Waiting for dependencies to be ready..."
        sleep 5

        for service_name in "${!DEPENDENCIES[@]}"; do
            print_info "Waiting for $service_name to be ready..."
            kubectl wait --for=condition=ready pod -l app=$service_name --timeout=120s || print_warn "$service_name may not be ready yet"
        done

        print_info "Dependencies are ready!"
    fi

    # Process each API
    for api_name in "${!APIS[@]}"; do
        # Check if we should deploy this API
        if ! should_deploy "$api_name"; then
            print_info "Skipping $api_name (not in filter)"
            continue
        fi

        IFS=':' read -r dir image_name ports namespace <<< "${APIS[$api_name]}"

        echo ""
        print_info "Processing $api_name..."

        check_directory "$dir" || continue
        check_dockerfile "$dir" || continue
        build_image "$dir" "$image_name" || continue
        create_namespace "$namespace" || continue
        generate_manifests "$api_name" "$image_name" "$ports" "$namespace" || continue
        deploy_to_k8s "$api_name" || continue
    done

    echo ""
    if [ -n "$exclude_filter" ]; then
        print_info "All services processed (excluded: $exclude_filter)"
    elif [ -n "$deploy_filter" ]; then
        print_info "Selected services processed: $deploy_filter"
    else
        print_info "All services processed!"
    fi
    echo ""

    # Wait for all deployments to be ready
    print_info "Waiting for all deployments to be ready..."
    for api_name in "${!APIS[@]}"; do
        print_info "Waiting for $api_name..."
        kubectl wait --for=condition=available deployment/$api_name --timeout=120s 2>/dev/null || print_warn "$api_name may not be ready yet"
    done

    echo ""
    print_info "All deployments ready!"
    echo ""

    show_status

    echo ""
    print_info "Deployment complete!"
    echo ""
    print_info "Access points:"
    echo "  - Core UI: http://dev.core-ui.local:3000/"
    echo ""
    print_info "For debugging (port-forward required):"
    echo "  - Prometheus: kubectl port-forward service/prometheus 19090:19090"
    echo "  - Then open: http://localhost:19090"
}

# Run main function
main "$@"