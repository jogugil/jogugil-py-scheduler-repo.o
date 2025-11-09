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

# Imágenes
SCHED_IMAGE="my-py-scheduler:latest"
CPU_IMAGE="cpu-heavy:latest"
RAM_IMAGE="ram-heavy:latest"
NGINX_IMAGE="nginx:latest"

# Rutas relativas
POLLING_PATH="../../variants/polling/scheduler.py"
WATCH_PATH="../../variants/watch-skeleton/scheduler.py"
DOCKERFILE_PATH="../../Dockerfile"
RBAC_PATH="../../rbac-deploy.yaml"

# Pods
POD_TYPES=("cpu" "ram" "nginx")

declare -A METRICS

# =============================================
# Función para copiar el scheduler seleccionado
# =============================================
copy_scheduler() {
    if [[ "$SCHED_IMPL" == "polling" ]]; then
        echo "Copiando scheduler-polling..."
        cp "$POLLING_PATH" ./scheduler.py
    elif [[ "$SCHED_IMPL" == "watch" ]]; then
        echo "Copiando scheduler-watch..."
        cp "$WATCH_PATH" ./scheduler.py
    else
        echo "Implementación desconocida: $SCHED_IMPL"
        exit 1
    fi
}

# =============================================
# Preparar cluster
# =============================================
prepare_cluster() {
    echo "=== Preparando cluster $CLUSTER_NAME ==="
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    kind create cluster --name "$CLUSTER_NAME"
    echo -n "Esperando nodo Ready"
    until kubectl get node "$CLUSTER_NAME-control-plane" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; do
        echo -n "."
        sleep 2
    done
    echo " listo!"
}

# =============================================
# Construir y cargar imágenes
# =============================================
build_and_load_image() {
    IMAGE_NAME=$1
    DIR=$2
    echo "Construyendo imagen $IMAGE_NAME desde $DIR..."
    docker build -t "$IMAGE_NAME" "$DIR"
    kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"
}

# =============================================
# Desplegar scheduler
# =============================================
deploy_scheduler() {
    echo "=== Desplegando scheduler $SCHED_IMPL ==="
    kubectl delete deployment my-scheduler -n kube-system --ignore-not-found
    cp "$RBAC_PATH" ./rbac-deploy.yaml
    kubectl apply -f ./rbac-deploy.yaml
    kubectl rollout status deployment/my-scheduler -n kube-system --timeout=120s
}

# =============================================
# Lanzar pods de prueba
# =============================================
launch_pods() {
    TYPE=$1
    COUNT=$2
    YAML_FILE="./${TYPE}-pod.yaml"
    echo "=== Lanzando $COUNT pods tipo $TYPE ==="
    for i in $(seq 1 $COUNT); do
        POD_NAME="${TYPE}-pod-$i"
        kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found
        kubectl apply -f "$YAML_FILE" -n "$NAMESPACE"
    done
    echo "Esperando a que los pods estén Ready..."
    kubectl wait --for=condition=Ready pod -l type=$TYPE -n "$NAMESPACE" --timeout=300s
}

# =============================================
# Medir métricas del scheduler
# =============================================
measure_scheduler_metrics() {
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=my-scheduler -o name | head -1 | sed 's#pod/##')
    local cpu_sum=0 mem_sum=0 samples=0
    for i in {1..3}; do
        local top_output=$(kubectl top pod "$scheduler_pod" -n kube-system 2>/dev/null || echo "")
        if [[ -n "$top_output" ]]; then
            local cpu=$(echo "$top_output" | awk 'NR>1{print $2}' | sed 's/m//')
            local mem=$(echo "$top_output" | awk 'NR>1{print $3}' | sed 's/Mi//')
            cpu_sum=$((cpu_sum + cpu))
            mem_sum=$((mem_sum + mem))
            samples=$((samples + 1))
        fi
        sleep 1
    done
    if [[ $samples -gt 0 ]]; then
        METRICS["cpu_avg"]=$((cpu_sum / samples))
        METRICS["mem_avg"]=$((mem_sum / samples))
    else
        METRICS["cpu_avg"]=0
        METRICS["mem_avg"]=0
    fi
}

# =============================================
# Ejecución principal
# =============================================
main() {
    copy_scheduler
    prepare_cluster

    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    kubectl create namespace "$NAMESPACE"

    build_and_load_image "$SCHED_IMAGE" "../../"
    build_and_load_image "$CPU_IMAGE" "./cpu-heavy"
    build_and_load_image "$RAM_IMAGE" "./ram-heavy"
    build_and_load_image "$NGINX_IMAGE" "./nginx"

    deploy_scheduler

    for TYPE in "${POD_TYPES[@]}"; do
        launch_pods "$TYPE" "$NUM_PODS"
    done

    measure_scheduler_metrics

    echo "{ \"scheduler\": \"$SCHED_IMPL\", \"num_pods\": $NUM_PODS, \"metrics\": { \"cpu_avg_m\": ${METRICS["cpu_avg"]}, \"mem_avg_Mi\": ${METRICS["mem_avg"]} } }" > "$RESULTS_JSON"
    echo "=== Resultados guardados en $RESULTS_JSON ==="
}

main "$@"
