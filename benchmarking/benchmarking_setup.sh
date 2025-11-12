#!/bin/bash

# ========================================
# CARGAR LOGGING Y MANEJO DE ERRORES
# ========================================
source ./logger.sh
enable_error_trapping

# =============================================
# Parámetros (vienen de run_benchmark.sh)
# =============================================
SCHED_IMPL=${1:-watch}   # polling o watch
NUM_PODS=${2:-20}        # Número de pods por tipo

NAMESPACE="test-scheduler"
CLUSTER_NAME="sched-lab"
RESULTS_JSON="scheduler_metrics_$(date +%Y%m%d_%H%M%S).json"

# Manifiestos
CLUSTERT_SETUP="kind-cluster.yaml"
RBAC_SCHEDULER="rbac-deploy.yaml"
CPU_POD="./cpu-heavy/cpu-heavy-pod.yaml"
NGINX_POD="./nginx/nginx_pod.yaml"
RAM_POD="./ram-heavy/ram-heavy-pod.yaml"
BASIC_POD="./test-basic/test-basic-pod.yaml"

# Imágenes
SCHED_IMAGE="my-py-scheduler:latest"
CPU_IMAGE="cpu-heavy:latest"
RAM_IMAGE="ram-heavy:latest"
NGINX_IMAGE="nginx:latest"
BASIC_IMAGE="pause:3.9"

# Rutas relativas
POLLING_PATH="../variants/polling/scheduler.py"
WATCH_PATH="../variants/watch-skeleton/scheduler.py"
DOCKERFILE_PATH="../Dockerfile"
RBAC_PATH="../rbac-deploy.yaml"

# Parametrop Debug y Métricas
RESULTS_FILE="scheduler_metrics_$(date +%Y%m%d_%H%M%S).csv"
LOGOUT_DEBUG="log/bechmarking.log"
METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml"

# Pods
POD_TYPES=("cpu" "ram" "nginx" "basic")

# ========================
# Funciones
# ========================

# Ejecutar un comando "seguro" que no detenga el script si falla
safe_run() {
    "$@" || log "WARN" "Comando '$*' falló pero se ignora"
}

# Espera que la imagen esté disponible en todos los nodos
wait_for_image() {
    local IMAGE=$1
    local NODE=$2
    local TIMEOUT=${3:-60}
    local INTERVAL=${4:-2}

    IMAGE_BASENAME="${IMAGE##*/}"
    local START=$(date +%s)
    log "INFO" "Esperando imagen $IMAGE en nodo $NODE"

    while true; do
        if docker exec "$NODE" crictl images | awk '{print $1":"$2}' | grep -q "$IMAGE_BASENAME"; then
            log "INFO" "Imagen $IMAGE cargada correctamente en nodo $NODE"
            break
        fi
        local NOW=$(date +%s)
        if (( NOW > START + TIMEOUT )); then
            log "ERROR" "Timeout cargando imagen $IMAGE en nodo $NODE después de $TIMEOUT segundos"
            exit 1
        fi
        log "DEBUG" "Imagen $IMAGE aún no disponible en $NODE, reintentando en $INTERVAL segundos..."
        sleep "$INTERVAL"
    done
}

# Carga y construye imagen en todos los nodos
load_image_to_cluster() {
    local IMAGE_NAME=$1
    local BUILD_DIR=$2
    local ONLY_MASTER=$3

    log "INFO" "Iniciando construcción de imagen [$IMAGE_NAME] desde directorio [$BUILD_DIR]"

    if docker build -t "$IMAGE_NAME" "$BUILD_DIR"; then
        log "INFO" "Imagen $IMAGE_NAME construida exitosamente"
    else
        log "ERROR" "Fallo en la construcción de la imagen $IMAGE_NAME desde $BUILD_DIR"
        exit 1
    fi

    # Obtenemos todos los nodos del clúster
    mapfile -t ALL_NODES < <(kind get nodes --name "$CLUSTER_NAME")

    if [[ ${#ALL_NODES[@]} -eq 1 ]]; then
        node="${ALL_NODES[0]}"
        log "INFO" "Cargando imagen $IMAGE_NAME en el único nodo: [$node]"
        if kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" --nodes "$node"; then
            wait_for_image "$IMAGE_NAME" "$node"
        else
            log "ERROR" "Fallo al cargar imagen $IMAGE_NAME en nodo $node"
            exit 1
        fi
    else
        for node in "${ALL_NODES[@]}"; do
            if [[ "$ONLY_MASTER" == "true" && $node == *control-plane* ]]; then
                log "INFO" "Cargando imagen $IMAGE_NAME en nodo control-plane: [$node]"
                if kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" --nodes "$node"; then
                    wait_for_image "$IMAGE_NAME" "$node"
                else
                    log "ERROR" "Fallo al cargar imagen $IMAGE_NAME en control-plane $node"
                    exit 1
                fi
            elif [[ "$ONLY_MASTER" != "true" && $node == *worker* ]]; then
                log "INFO" "Cargando imagen $IMAGE_NAME en nodo worker: [$node]"
                if kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" --nodes "$node"; then
                    wait_for_image "$IMAGE_NAME" "$node"
                else
                    log "ERROR" "Fallo al cargar imagen $IMAGE_NAME en worker $node"
                    exit 1
                fi
            fi
        done
    fi

    log "INFO" "Imagen $IMAGE_NAME cargada exitosamente en todos los nodos seleccionados"
}

# Crear clúster nuevo o reiniciar existente
create_cluster() {
    if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        log "INFO" "Eliminando cluster existente $CLUSTER_NAME"
        safe_run kind delete cluster --name "$CLUSTER_NAME"
    fi

    log "INFO" "Creando nuevo cluster $CLUSTER_NAME"
    if kind create cluster --name "$CLUSTER_NAME" --config $CLUSTERT_SETUP; then
        log "INFO" "Cluster $CLUSTER_NAME creado exitosamente"
    else
        log "ERROR" "Fallo al crear cluster $CLUSTER_NAME"
        exit 1
    fi

    log "INFO" "Esperando que nodo control-plane esté en estado Ready"
    local wait_time=0
    local max_wait=120
    until kubectl get node "$CLUSTER_NAME-control-plane" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; do
        if (( wait_time >= max_wait )); then
            log "ERROR" "Timeout esperando por nodo control-plane después de $max_wait segundos"
            exit 1
        fi
        log "DEBUG" "Nodo control-plane aún no está Ready, esperando... ($wait_time/$max_wait segundos)"
        sleep 2
        ((wait_time+=2))
    done
    log "INFO" "Nodo control-plane está Ready y operativo"
}

# Limpiar recursos antiguos en namespace
clean_namespace() {
    log "INFO" "Limpiando namespace $NAMESPACE"

    safe_run kubectl delete --all pods --namespace "$NAMESPACE"
    safe_run kubectl delete --all deployments --namespace "$NAMESPACE"

    if ! kubectl get namespace "$NAMESPACE"; then
        log "INFO" "Creando namespace $NAMESPACE"
        if kubectl create namespace "$NAMESPACE"; then
            log "INFO" "Namespace $NAMESPACE creado exitosamente"
        else
            log "ERROR" "Fallo al crear namespace $NAMESPACE"
            exit 1
        fi
    else
        log "DEBUG" "Namespace $NAMESPACE ya existe"
    fi
}

# =============================================
# Función para copiar el scheduler seleccionado
# =============================================
copy_scheduler() {
    local SCHED_IMPL=$1
    case "$SCHED_VARIANT" in
        polling)
            log "INFO" "Copiando scheduler-polling desde $POLLING_PATH"
            if cp "$POLLING_PATH" ./scheduler.py; then
                log "DEBUG" "Scheduler polling copiado exitosamente"
            else
                log "ERROR" "Fallo al copiar scheduler polling desde $POLLING_PATH"
                exit 1
            fi
            ;;
        watch)
            log "INFO" "Copiando scheduler-watch desde $WATCH_PATH"
            if cp "$WATCH_PATH" ./scheduler.py; then
                log "DEBUG" "Scheduler watch copiado exitosamente"
            else
                log "ERROR" "Fallo al copiar scheduler watch desde $WATCH_PATH"
                exit 1
            fi
            ;;
        *)
            log "ERROR" "Implementación de scheduler desconocida: $SCHED_VARIANT"
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
            log "INFO" "No se pasó parámetro de scheduler, se usará por defecto: $SCHED_VARIANT"
            ;;
        polling|watch)
            SCHED_VARIANT="$VARIANT_PARAM"
            log "INFO" "Scheduler seleccionado por parámetro: $SCHED_VARIANT"
            ;;
        *)
            log "WARN" "Parámetro inválido '$VARIANT_PARAM'. Solo se permiten 'polling' o 'watch'. Se usará por defecto: $DEFAULT_VARIANT"
            ;;
    esac

    log "INFO" "Variante de scheduler seleccionada: $SCHED_VARIANT"
    copy_scheduler $SCHED_VARIANT
    log "INFO" "Scheduler copiado exitosamente a ./scheduler.py"
}

# ========================
# Install metrics-server if needed
# Me da problemas al bajarme la imagen del servidor de metricas.
# ========================
install_metrics_server_old() {
    METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml"

    echo "=== Comprobando si Metrics Server ya está instalado ==="
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        echo "=== Instalando Metrics Server ==="
        kubectl apply -f "$METRICS_SERVER_URL"

        echo "=== Parcheando TLS inseguro ==="
        kubectl patch deployment metrics-server -n kube-system --type='json' \
            -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

        echo "=== Esperando Metrics Server disponible (timeout 120s) ==="
        if ! kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system &>/dev/null; then
            echo "⚠️  Atención: Metrics Server no disponible después de 120s, continuando..."
        else
            echo "✅ Metrics Server está disponible"
        fi
    else
        echo "=== Metrics Server ya está instalado ==="
    fi

    echo "=== Pausa de 30 segundos para estabilizar ==="
    sleep 30
}
install_metrics_server() {
    METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml"
    METRICS_IMAGE="registry.k8s.io/metrics-server/metrics-server:v0.6.3"

    echo "=== Comprobando si Metrics Server ya está instalado ==="
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        echo "=== Descargando imagen Metrics Server localmente ==="
        docker pull "$METRICS_IMAGE"

        echo "=== Cargando imagen Metrics Server en todos los nodos Kind ==="
        for node in $(kind get nodes --name "$CLUSTER_NAME"); do
            echo "=== Cargando imagen en $node ==="
            kind load docker-image "$METRICS_IMAGE" --name "$CLUSTER_NAME" --nodes "$node"
        done

        echo "=== Aplicando manifiesto Metrics Server ==="
        kubectl apply -f "$METRICS_SERVER_URL"

        echo "=== Parcheando TLS inseguro ==="
        kubectl patch deployment metrics-server -n kube-system --type='json' \
            -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

        echo "=== Esperando Metrics Server disponible (timeout 120s) ==="
        if ! kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system &>/dev/null; then
            echo "⚠️ Metrics Server no disponible después de 120s, continuando..."
        else
            echo "✅ Metrics Server está disponible"
        fi
    else
        echo "=== Metrics Server ya está instalado ==="
    fi

    echo "=== Pausa de 30 segundos para estabilizar ==="
    sleep 30
}
# ========================
# Function to show cluster and images info
# ========================
show_cluster_info() {
    log "DEBUG" "Mostrando información del cluster"

    log "INFO" "=== Listing all Kind clusters ==="
    safe_run kind get clusters

    log "INFO" "=== Showing nodes and status ==="
    safe_run kubectl get nodes -o wide

    log "INFO" "=== Cluster info ==="
    safe_run kubectl cluster-info

    log "INFO" "=== Listing namespaces ==="
    safe_run kubectl get ns

    log "INFO" "=== Listing all pods in all namespaces ==="
    safe_run kubectl get pods --all-namespaces -o wide

    log "INFO" "=== Checking images on each node ==="
    for node in $(kind get nodes); do
        log "DEBUG" "Imágenes en nodo $node:"
        safe_run docker exec $node crictl images
    done

    log "INFO" "=== Current pod metrics ==="
    safe_run kubectl top pods --all-namespaces
}

# =============================================
# Desplegar scheduler
# =============================================
deploy_scheduler() {
    local scheduler_type=$1
    log "INFO" "Iniciando despliegue del scheduler: $scheduler_type"

    log "DEBUG" "Eliminando despliegue previo del scheduler si existe"
    safe_run kubectl delete deployment my-scheduler -n kube-system --ignore-not-found

    log "INFO" "Aplicando configuración RBAC y Deployment del scheduler"
    if kubectl apply -f $RBAC_SCHEDULER; then
        log "DEBUG" "Manifiestos RBAC aplicados exitosamente"
    else
        log "ERROR" "Fallo al aplicar manifiestos RBAC del scheduler"
        exit 1
    fi

    log "INFO" "Esperando a que el scheduler se despliegue correctamente (timeout: 120s)"
    if kubectl rollout status deployment/my-scheduler -n kube-system --timeout=120s; then
        log "INFO" "Scheduler desplegado exitosamente"
    else
        log "ERROR" "Fallo en el despliegue del scheduler - mostrando diagnóstico"

        log "ERROR" "=== Descripción del pod del scheduler ==="
        safe_run kubectl describe pod -n kube-system -l app=my-scheduler

        log "ERROR" "=== Logs del scheduler ==="
        safe_run kubectl logs -n kube-system -l app=my-scheduler --tail=50

        log "ERROR" "=== Estado de los pods en kube-system ==="
        safe_run kubectl get pods -n kube-system

        exit 1
    fi
}

# ========================
# Ejecución principal
# ========================

main() {
    log "INFO" "=== INICIO SETUP COMPLETO DEL ENTORNO DE BENCHMARKING ==="

    # Limpiar imágenes locales y contenedores detenidos
    log "INFO" "Limpiando imágenes y contenedores locales"
    safe_run docker image rm -f "$CPU_IMAGE" "$RAM_IMAGE" "$SCHED_IMAGE"
    safe_run docker container prune -f

    # Selección de variante de scheduler
    select_scheduler_variant "$1"

    # Copiar Dockerfile y requirements al directorio actual
    log "DEBUG" "Copiando archivos de configuración al directorio actual"
    if cp ../Dockerfile ./Dockerfile && \
       cp ../requirements.txt ./requirements.txt && \
       cp ../rbac-deploy.yaml ./rbac-deploy.yaml; then
        log "DEBUG" "Archivos de configuración copiados exitosamente"
    else
        log "ERROR" "Fallo al copiar archivos de configuración"
        exit 1
    fi

    # Crear clúster nuevo
    create_cluster

    # Limpiar namespace y recursos antiguos
    clean_namespace

    # Construir y cargar imagen del scheduler
    log "INFO" "Construyendo y cargando imagen del scheduler personalizado"
    load_image_to_cluster "$SCHED_IMAGE" "./" "true"

    # Construir y cargar imágenes basic/nginx/CPU/RAM
    log "INFO" "Construyendo y cargando imágenes de prueba"
    load_image_to_cluster "$BASIC_IMAGE" "./test-basic" "false"
    load_image_to_cluster "$NGINX_IMAGE" "./nginx" "false"
    load_image_to_cluster "$CPU_IMAGE" "./cpu-heavy" "false"
    load_image_to_cluster "$RAM_IMAGE" "./ram-heavy" "false"

    # Cargamos módulos de métricas
    log "INFO" "Configurando métricas del cluster"
    install_metrics_server

    log "DEBUG" "Mostrando estado actual del cluster"
    show_cluster_info

    log "INFO" "=== ENTORNO COMPLETO LISTO PARA TESTS ==="

    # Desplegamos el scheduler custom (watch o polling)
    deploy_scheduler "$SCHED_IMPL"

    # Ejecutar el script de benchmarking de pods
    SCHED_IMPL=${SCHED_IMPL:-polling}
    NUM_PODS=${NUM_PODS:-20}

    log "INFO" "Iniciando tests de benchmarking con scheduler: $SCHED_IMPL, pods por tipo: $NUM_PODS"
    log "INFO" "=== LANZANDO TEST DE PODS EN PARALELO ==="

    if ./scheduler-test.sh "$SCHED_IMPL" "$NUM_PODS"; then
        log "INFO" "Tests de pods ejecutados exitosamente"
    else
        log "ERROR" "Fallo en la ejecución de los tests de pods"
        exit 1
    fi

    # Una vez termine, los resultados ya estarán en $RESULTS_DIR y $RESULTS_JSON
    log "INFO" "=== TEST DE PODS FINALIZADO ==="
    log "INFO" "Resultados CSV: ./my-scheduler/metrics/results.csv"
    log "INFO" "Resultados JSON: ./$SCHED_IMPL/metrics/scheduler_metrics_*.json"
    log "INFO" "Resultados se guardarán en $RESULTS_FILE"

    log "INFO" "=== SETUP COMPLETO FINALIZADO EXITOSAMENTE ==="
}

# Ejecutar función principal
main "$@"
