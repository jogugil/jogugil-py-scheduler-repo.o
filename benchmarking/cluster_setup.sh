#!/bin/bash
set -e

CLUSTER_NAME="sched-lab"
NAMESPACE="test-scheduler"
SCHED_IMAGE="my-py-scheduler:latest"
CPU_IMAGE="cpu-heavy:latest"
RAM_IMAGE="ram-heavy:latest"
RESULTS_FILE="scheduler_metrics_$(date +%Y%m%d_%H%M%S).csv"
BASIC_IMAGE="pause:3.9"
NGINX_IMAGE="nginx:latest"

# ========================
# Funciones
# ========================

# Espera que la imagen esté disponible en todos los nodos
wait_for_image() {
    local IMAGE=$1
    local NODE=$2
    local TIMEOUT=${3:-60}
    local INTERVAL=${4:-2}

    IMAGE_BASENAME="${IMAGE##*/}"
    local START=$(date +%s)
    echo -n "Esperando imagen $IMAGE en nodo $NODE "
    while true; do
        if docker exec "$NODE" crictl images | awk '{print $1":"$2}' | grep -q "$IMAGE_BASENAME"; then
            echo " ✔"
            break
        fi
        local NOW=$(date +%s)
        (( NOW > START + TIMEOUT )) && { echo; echo "ERROR: Timeout cargando imagen $IMAGE"; exit 1; }
        echo -n "."
        sleep "$INTERVAL"
    done
}

# Carga y construye imagen en todos los nodos
load_image_to_cluster() {
    local IMAGE_NAME=$1
    local BUILD_DIR=$2

    echo "=== Construyendo imagen $IMAGE_NAME ==="
    docker build -t "$IMAGE_NAME" "$BUILD_DIR"

    echo "=== Cargando imagen $IMAGE_NAME en Kind ==="
    kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"

    for NODE in $(kind get nodes --name "$CLUSTER_NAME"); do
        wait_for_image "$IMAGE_NAME" "$NODE"
    done
    echo "=== Imagen $IMAGE_NAME disponible en todos los nodos ==="
}

# Crear clúster nuevo o reiniciar existente
create_cluster() {
    if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        echo "=== Eliminando cluster existente $CLUSTER_NAME ==="
        kind delete cluster --name "$CLUSTER_NAME"
    fi

    echo "=== Creando cluster $CLUSTER_NAME ==="
    kind create cluster --name "$CLUSTER_NAME"

    echo -n "Esperando nodo control-plane Ready"
    until kubectl get node "$CLUSTER_NAME-control-plane" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; do
        echo -n "."
        sleep 2
    done
    echo " listo"
}

# Limpiar recursos antiguos en namespace
clean_namespace() {
    echo "=== Limpiando namespace $NAMESPACE ==="
    kubectl delete --all pods --namespace "$NAMESPACE" || true
    kubectl delete --all deployments --namespace "$NAMESPACE" || true
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "=== Creando namespace $NAMESPACE ==="
        kubectl create namespace "$NAMESPACE"
    fi
}

# ========================
# Función: seleccionar y copiar la variante del scheduler
# ========================
select_scheduler_variant() {
    local VARIANT_PARAM=$1
    local DEFAULT_VARIANT="watch"

    if [[ -z "$VARIANT_PARAM" ]]; then
        SCHED_VARIANT="$DEFAULT_VARIANT"
        echo "No se pasó parámetro de scheduler, se usará por defecto: $SCHED_VARIANT"
    elif [[ "$VARIANT_PARAM" != "polling" && "$VARIANT_PARAM" != "watch" ]]; then
        echo "Parámetro inválido '$VARIANT_PARAM'. Solo se permiten 'polling' o 'watch'. Se usará por defecto: $DEFAULT_VARIANT"
        SCHED_VARIANT="$DEFAULT_VARIANT"
    else
        SCHED_VARIANT="$VARIANT_PARAM"
    fi

    echo "=== Variante de scheduler seleccionada: $SCHED_VARIANT ==="

    case "$SCHED_VARIANT" in
        polling)
            cp ../../variants/polling/scheduler.py ./scheduler.py
            ;;
        watch)
            cp ../../variants/watch-skeleton/scheduler.py ./scheduler.py
            ;;
    esac
    echo "=== Scheduler copiado a ./scheduler.py ==="
}

# ========================
# Install metrics-server if needed
# ========================
install_metrics_server() {
    if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
        echo "=== Installing metrics-server ==="
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        kubectl patch deployment metrics-server -n kube-system --type='json' \
            -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
        kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system
    fi

    echo "=== Waiting for metrics-server to be ready ==="
    sleep 30
}


# ========================
# Function to show cluster and images info
# ========================
show_cluster_info() {
    echo "=== Listing all Kind clusters ==="
    kind get clusters

    echo -e "\n=== Showing nodes and status ==="
    kubectl get nodes -o wide

    echo -e "\n=== Cluster info ==="
    kubectl cluster-info

    echo -e "\n=== Listing namespaces ==="
    kubectl get ns

    echo -e "\n=== Listing all pods in all namespaces ==="
    kubectl get pods --all-namespaces -o wide

    echo -e "\n=== Checking images on each node ==="
    for node in $(kind get nodes); do
        echo "=== Images in node $node ==="
        docker exec $node crictl images
    done

    echo -e "\n=== Current pod metrics ==="
    kubectl top pods --all-namespaces || echo "No resources found"
}

# ========================
# Ejecución principal
# ========================

echo "=== INICIO SETUP COMPLETO ==="

# Limpiar imágenes locales y contenedores detenidos
echo "=== Limpiando imágenes y contenedores locales ==="
docker image rm -f "$CPU_IMAGE" "$RAM_IMAGE" "$SCHED_IMAGE" >/dev/null 2>&1 || true
docker container prune -f

# Selección de variante de scheduler
select_scheduler_variant "$1"

# Copiar Dockerfile y requirements al directorio actual
cp ../../Dockerfile ./Dockerfile
cp ../../requirements.txt ./requirements.txt
cp ../../rbac-deploy.yaml ./rbac-deploy.yaml

# Limpiar imágenes locales y contenedores detenidos
echo "=== Limpiando imágenes y contenedores locales ==="
docker image rm -f "$CPU_IMAGE" "$RAM_IMAGE" "$SCHED_IMAGE" >/dev/null 2>&1 || true
docker container prune -f

# Crear clúster nuevo
create_cluster

# Limpiar namespace y recursos antiguos
clean_namespace

# Construir y cargar imagen del scheduler
load_image_to_cluster "$SCHED_IMAGE" "./"

# Construir y cargar imágenes basic/nginx/CPU/RAM
load_image_to_cluster "$BASIC_IMAGE" "./test-basic"
load_image_to_cluster "$NGINX_IMAGE" "./nginx-pod"
load_image_to_cluster "$CPU_IMAGE" "./cpu-heavy"
load_image_to_cluster "$RAM_IMAGE" "./ram-heavy"
# Construir y cargar imágenes CPU/RAM
load_image_to_cluster "$CPU_IMAGE" "./cpu-heavy"
load_image_to_cluster "$RAM_IMAGE" "./ram-heavy"
# Cargamos módulos de métricas
install_metrics_server
show_cluster_info

# Vemos lo que hemso cosntruido
show_cluster_info

echo "=== ENTORNO COMPLETO LISTO PARA TESTS ==="

# Desplegamos el scheduler custom (watch o polling)
deploy_scheduler

# Ejecutar el script de benchmarking de pods
# Podemos pasarle la variante de scheduler y el número de pods opcionalmente
SCHED_IMPL=${SCHED_IMPL:-polling}  # la misma variante que usamos arriba
NUM_PODS=${NUM_PODS:-20}           # por defecto 20 pods
echo "=== LANZANDO TEST DE PODS EN PARALELO ==="
./bechmarking/scheduler-test.sh "$SCHED_IMPL" "$NUM_PODS"

# Una vez termine, los resultados ya estarán en $RESULTS_DIR y $RESULTS_JSON
echo "=== TEST DE PODS FINALIZADO ==="
echo "Resultados CSV: ./my-scheduler/metrics/results.csv"
echo "Resultados JSON: ./$SCHED_IMPL/metrics/scheduler_metrics_*.json"


echo "Resultados se guardarán en $RESULTS_FILE"
