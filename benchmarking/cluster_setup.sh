#!/bin/bash
set -e


# =============================================
# Parámetros
# =============================================
SCHED_IMPL=${1:-polling}   # polling o watch
NUM_PODS=${2:-20}          # Número de pods por tipo
NAMESPACE="test-scheduler"
CLUSTER_NAME="sched-lab"
RESULTS_JSON="scheduler_metrics_$(date +%Y%m%d_%H%M%S).json"

# Manifiestos
CLUSTERT_SETUP="kind-cluster.yaml"
RBAC_SCHEDULER="rbac-deploy.yaml"
CPU_POD="./cpu-heavy/cpu-heavy-pod.yaml"
NGINX_POD="./nginx-pod/nginx_pod.yaml"
RAM_POD="./ram-heavy/ram-heavy-pod.yaml"
BASIC_POD="./test-basic/test-basic.yaml"

# Imágenes
SCHED_IMAGE="my-py-scheduler:latest"
CPU_IMAGE="cpu-heavy:latest"
RAM_IMAGE="ram-heavy:latest"
NGINX_IMAGE="nginx:latest"
BASIC_IMAGE="pause:3.9"

# Rutas relativas
POLLING_PATH="../../variants/polling/scheduler.py"
WATCH_PATH="../../variants/watch-skeleton/scheduler.py"
DOCKERFILE_PATH="../../Dockerfile"
RBAC_PATH="../../rbac-deploy.yaml"

# Parametrop Debug y Métricas
RESULTS_FILE="scheduler_metrics_$(date +%Y%m%d_%H%M%S).csv"
LOGOUT_DEBUG="log/bechmarking.log"


# Pods
POD_TYPES=("cpu" "ram" "nginx" "basic")


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
    local IMAGE_NAME=$1                     # Guardamos el nombre de la imagen que queremos construir y cargar
    local BUILD_DIR=$2                      # Guardamos el directorio desde el que construiremos la imagen
    local ONLY_MASTER=$3                  # true → cargar solo en control-plane; false → solo workers

    echo "=== Construyendo imagen [$IMAGE_NAME] desde [$BUILD_DIR] ==="   # Informamos de que iniciamos la construcción
    docker build -t "$IMAGE_NAME" "$BUILD_DIR"                            # Construimos la imagen Docker con la etiqueta indicada

    ALL_NODES=$(kind get nodes --name "$CLUSTER_NAME")   # Obtenemos todos los nodos del clúster
    # Seleccionamos los nodos destino
    local TARGET_NODES
    if [[ "$ONLY_MASTER" == "true" ]]; then
        TARGET_NODES=$(echo "$ALL_NODES" | grep "control-plane")
    else
        TARGET_NODES=$(echo "$ALL_NODES" | grep "worker")

        # Si no hay workers, usamos el control-plane
        if [[ -z "$TARGET_NODES" ]]; then
            TARGET_NODES="$ALL_NODES"
        fi
    fi
    # De esta forma optimizamos cuando el scheduler asigna a cualquier nodo el Pod. Ya tenemos su imagen cargada y optimizamos tiempo
    for NODE in $TARGET_NODES; do             # Recorremos la lista de nodos donde quiero cargar la imagen (wrokers <- Pods, controil Plane <- scheduler)
        echo "=== Cargando imagen $IMAGE_NAME en el node :[$NODE] ==="
        kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" --nodes "$NODE"  # Cargamos la imagen en el nodo que deseamos 
        wait_for_image "$IMAGE_NAME" "$NODE"  # Esperamos a que cada nodo vea la imagen
    done

    echo "=== Imagen $IMAGE_NAME disponible en todos los nodos ==="       # Confirmamos que la imagen ya está disponible en todos los nodos
}

# Crear clúster nuevo o reiniciar existente
create_cluster() {
    if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        echo "=== Eliminando cluster existente $CLUSTER_NAME ==="
        kind delete cluster --name "$CLUSTER_NAME"  >/dev/null 2>&1 || true
    fi

    echo "=== Creando cluster $CLUSTER_NAME ==="
    kind create cluster --name "$CLUSTER_NAME"  --config $CLUSTERT_SETUP

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

# ========================================================
# Función: seleccionar y copiar la variante del scheduler
# ========================================================
# =============================================
# Función para copiar el scheduler seleccionado
# =============================================
copy_scheduler() {
    local SCHED_IMPL=$1
    case "$SCHED_VARIANT" in
        polling)
            echo "Copiando scheduler-polling..."
            cp "$POLLING_PATH" ./scheduler.py
            ;;
        watch)
            echo "Copiando scheduler-watch..."
            cp "$WATCH_PATH" ./scheduler.py
            ;;
        *)
            echo "Implementación desconocida: $SCHED_VARIANT"
            exit 1
        ;;
    esac
}
select_scheduler_variant() {
    local VARIANT_PARAM=$1
    local DEFAULT_VARIANT="watch"
    local SCHED_VARIANT=$DEFAULT_VARIANT

    case "$VARIANT_PARAM" in
        "")
            echo "No se pasó parámetro de scheduler, se usará por defecto: $SCHED_VARIANT"
            ;;
        polling|watch)
            SCHED_VARIANT="$VARIANT_PARAM"
            ;;
        *)
            echo "Parámetro inválido '$VARIANT_PARAM'. Solo se permiten 'polling' o 'watch'. Se usará por defecto: $DEFAULT_VARIANT"
            ;;
    esac
    echo "=== Variante de scheduler seleccionada: $SCHED_VARIANT ==="

    copy_scheduler $SCHED_VARIANT
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

# =============================================
# Desplegar scheduler
# =============================================
deploy_scheduler() {
    echo "=== Desplegando scheduler $SCHED_IMPL ==="            # Informamos qué variante de scheduler vamos a desplegar

    kubectl delete deployment my-scheduler -n kube-system --ignore-not-found
    # Eliminamos cualquier despliegue previo del scheduler para evitar conflictos
    # --ignore-not-found evita error si no existía antes

    kubectl apply -f $RBAC_SCHEDULER
    # Aplicamos los manifiestos del scheduler (RBAC, ServiceAccount, Deployment, etc.)

    kubectl rollout status deployment/my-scheduler -n kube-system --timeout=120s
    # Esperamos a que el Deployment se despliegue correctamente
    # Esto asegura que el scheduler esté listo antes de ejecutar cualquier pod que dependa de él
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
# Cargamos módulos de métricas
install_metrics_server
show_cluster_info

# Vemos lo que hemso cosntruido
show_cluster_info

echo "=== ENTORNO COMPLETO LISTO PARA TESTS ==="

# Desplegamos el scheduler custom (watch o polling)
deploy_scheduler 'watch'

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

