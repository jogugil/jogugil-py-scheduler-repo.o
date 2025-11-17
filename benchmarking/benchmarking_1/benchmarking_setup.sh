#!/bin/bash

# ========================================
# CARGAR SISTEMA CENTRALIZADO
# ========================================
source ./logger.sh
enable_error_trapping

# =============================================
# Parámetros (vienen de run_benchmark.sh)
# =============================================
SCHED_IMPL=${1:-watch}   # polling o watch
NUM_PODS=${2:-1}         # Número de pods por tipo (SOLO 1 PARA PRUEBAS)

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

#
# Rutas relativas  ---123-- Cuidado porque si se cambia de directorio esto no sirve
POLLING_PATH="../../variants/polling/scheduler.py"
WATCH_PATH="../../variants/watch-skeleton/scheduler.py"
DOCKERFILE_PATH="../../Dockerfile"
RBAC_PATH="../../rbac-deploy.yaml"

# Parámetros Debug y Métricas
RESULTS_FILE="scheduler_metrics_$(date +%Y%m%d_%H%M%S).csv"
METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml"

# Pods (SOLO CPU PARA PRUEBAS)
POD_TYPES=("cpu")

# ========================
# Funciones con CHECKPOINTS
# ========================

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
            return 1
        fi
        log "DEBUG" "Imagen $IMAGE aún no disponible en $NODE, reintentando en $INTERVAL segundos..."
        sleep "$INTERVAL"
    done
    return 0
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
        return 1
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
            return 1
        fi
    else
        for node in "${ALL_NODES[@]}"; do
            if [[ "$ONLY_MASTER" == "true" && $node == *control-plane* ]]; then
                log "INFO" "Cargando imagen $IMAGE_NAME en nodo control-plane: [$node]"
                if kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" --nodes "$node"; then
                    wait_for_image "$IMAGE_NAME" "$node"
                else
                    log "ERROR" "Fallo al cargar imagen $IMAGE_NAME en control-plane $node"
                    return 1
                fi
            elif [[ "$ONLY_MASTER" != "true" && $node == *worker* ]]; then
                log "INFO" "Cargando imagen $IMAGE_NAME en nodo worker: [$node]"
                if kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" --nodes "$node"; then
                    wait_for_image "$IMAGE_NAME" "$node"
                else
                    log "ERROR" "Fallo al cargar imagen $IMAGE_NAME en worker $node"
                    return 1
                fi
            fi
        done
    fi

    log "INFO" "Imagen $IMAGE_NAME cargada exitosamente en todos los nodos seleccionados"
    return 0
}
# Crear clúster nuevo o reiniciar existente
create_cluster() {
    checkpoint "cluster_creation_start" "Iniciando creación del cluster Kind"

    if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        log "INFO" "Eliminando cluster existente $CLUSTER_NAME"
        if ! safe_run "Eliminar cluster existente" kind delete cluster --name "$CLUSTER_NAME"; then
            log "ERROR" "Fallo al eliminar cluster existente"
            return 1
        fi
    fi

    log "INFO" "Creando nuevo cluster $CLUSTER_NAME"
    if ! safe_run "Crear cluster Kind" kind create cluster --name "$CLUSTER_NAME" --config $CLUSTERT_SETUP; then
        log "ERROR" "Fallo al crear cluster $CLUSTER_NAME"
        return 1
    fi

    log "INFO" "Cluster $CLUSTER_NAME creado exitosamente"

    log "INFO" "Esperando que nodo control-plane esté en estado Ready"
    local wait_time=0
    local max_wait=120
    until kubectl get node "$CLUSTER_NAME-control-plane" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; do
        if (( wait_time >= max_wait )); then
            log "ERROR" "Timeout esperando por nodo control-plane después de $max_wait segundos"
            return 1
        fi
        log "DEBUG" "Nodo control-plane aún no está Ready, esperando... ($wait_time/$max_wait segundos)"
        sleep 2
        ((wait_time+=2))
    done
    log "INFO" "Nodo control-plane está Ready y operativo"

    checkpoint "cluster_created" "Cluster Kind creado y nodo control-plane listo"
    return 0
}

# Limpiar recursos antiguos en namespace
clean_namespace() {
    checkpoint "namespace_cleanup_start" "Limpiando namespace $NAMESPACE"

    safe_run "Limpiar pods del namespace" kubectl delete --all pods --namespace "$NAMESPACE" --ignore-not-found=true --wait=false
    safe_run "Limpiar deployments del namespace" kubectl delete --all deployments --namespace "$NAMESPACE" --ignore-not-found=true --wait=false

    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log "INFO" "Creando namespace $NAMESPACE"
        if ! safe_run "Crear namespace" kubectl create namespace "$NAMESPACE"; then
            log "ERROR" "Fallo al crear namespace $NAMESPACE"
            return 1
        fi
    else
        log "DEBUG" "Namespace $NAMESPACE ya existe"
    fi

    checkpoint "namespace_cleaned" "Namespace $NAMESPACE limpio y listo"
    return 0
}

# =============================================
# Función para copiar el scheduler seleccionado
# =============================================
copy_scheduler() {
    local SCHED_IMPL=$1
    case "$SCHED_IMPL" in
        polling)
            log "INFO" "Copiando scheduler-polling desde $POLLING_PATH"
            if cp "$POLLING_PATH" ./scheduler.py; then
                log "DEBUG" "Scheduler polling copiado exitosamente"
            else
                log "ERROR" "Fallo al copiar scheduler polling desde $POLLING_PATH"
                return 1
            fi
            ;;
        watch)
            log "INFO" "Copiando scheduler-watch desde $WATCH_PATH"
            if cp "$WATCH_PATH" ./scheduler.py; then
                log "DEBUG" "Scheduler watch copiado exitosamente"
            else
                log "ERROR" "Fallo al copiar scheduler watch desde $WATCH_PATH"
                return 1
            fi
            ;;
        *)
            log "ERROR" "Implementación de scheduler desconocida: $SCHED_IMPL"
            return 1
            ;;
    esac
    return 0
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

    checkpoint "scheduler_selected" "Scheduler $SCHED_VARIANT seleccionado"

    if copy_scheduler $SCHED_VARIANT; then
        log "INFO" "Scheduler copiado exitosamente a ./scheduler.py"
        return 0
    else
        log "ERROR" "Fallo al copiar scheduler"
        return 1
    fi
}

# ========================
# Install metrics-server
# ========================
install_metrics_server() {
    checkpoint "metrics_server_start" "Instalando Metrics Server"

    METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml"
    METRICS_IMAGE="registry.k8s.io/metrics-server/metrics-server:v0.6.3"

    log "INFO" "Comprobando si Metrics Server ya está instalado"
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        log "INFO" "Descargando imagen Metrics Server localmente"
        if ! safe_run "Descargar imagen metrics-server" docker pull "$METRICS_IMAGE"; then
            log "WARN" "No se pudo descargar la imagen metrics-server, continuando..."
            return 0
        fi

        log "INFO" "Cargando imagen Metrics Server en todos los nodos Kind"
        for node in $(kind get nodes --name "$CLUSTER_NAME"); do
            log "INFO" "Cargando imagen en $node"
            safe_run "Cargar metrics-server en nodo" kind load docker-image "$METRICS_IMAGE" --name "$CLUSTER_NAME" --nodes "$node"
        done

        log "INFO" "Aplicando manifiesto Metrics Server"
        if ! safe_run "Aplicar metrics-server" kubectl apply -f "$METRICS_SERVER_URL"; then
            log "ERROR" "No se pudo aplicar metrics-server..."
            return 0
        fi

        log "INFO" "Parcheando TLS inseguro"
        safe_run "Parchear metrics-server" kubectl patch deployment metrics-server -n kube-system --type='json' \
            -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

        log "INFO" "Esperando Metrics Server disponible (timeout 60s)"
        if ! safe_run "Esperar metrics-server" kubectl wait --for=condition=available --timeout=60s deployment/metrics-server -n kube-system &>/dev/null; then
            log "ERROR" "Metrics Server no disponible después de 60s..."
        else
            log "INFO" "Metrics Server está disponible"
        fi
    else
        log "INFO" "Metrics Server ya está instalado"
    fi

    log "INFO" "Pausa de 10 segundos para estabilizar"
    sleep 10

    checkpoint "metrics_server_installed" "Metrics Server instalado y configurado"
    return 0
}

# ========================
# Function to show cluster and images info
# ========================
show_cluster_info() {
    log "INFO" "Mostrando información del cluster"

    log "INFO" "=== Listing all Kind clusters ==="
    safe_run "Listar clusters Kind" kind get clusters

    log "INFO" "=== Showing nodes and status ==="
    safe_run "Listar nodos" kubectl get nodes -o wide

    log "INFO" "=== Cluster info ==="
    safe_run "Info del cluster" kubectl cluster-info

    log "INFO" "=== Listing namespaces ==="
    safe_run "Listar namespaces" kubectl get ns

    log "INFO" "=== Listing all pods in all namespaces ==="
    safe_run "Listar todos los pods" kubectl get pods --all-namespaces -o wide

    log "INFO" "=== Checking images on each node ==="
    for node in $(kind get nodes --name "$CLUSTER_NAME"); do
        log "INFO" "Imágenes en nodo $node:"
        safe_run "Listar imágenes en nodo" docker exec "$node" crictl images || true
    done

    log "INFO" "=== Current pod metrics ==="
    safe_run "Métricas de pods" kubectl top pods --all-namespaces || log "WARN" "No se pudieron obtener métricas"
}

# =============================================
# Desplegar scheduler
# =============================================
deploy_scheduler() {
    local scheduler_type=$1
    log "INFO" "Iniciando despliegue del scheduler: $scheduler_type"
    
    checkpoint "scheduler_deployment_start" "Desplegando scheduler personalizado"

    log "INFO" "Eliminando despliegue previo del scheduler si existe"
    safe_run "Eliminar scheduler anterior" kubectl delete deployment my-scheduler -n kube-system --ignore-not-found=true

    log "INFO" "Aplicando configuración RBAC y Deployment del scheduler"
    if ! safe_run "Aplicar RBAC del scheduler" kubectl apply -f $RBAC_SCHEDULER; then
        log "ERROR" "Fallo al aplicar manifiestos RBAC del scheduler"
        return 1
    fi

    log "INFO" "Esperando a que el scheduler se despliegue correctamente (timeout: 120s)"
    if ! safe_run "Esperar despliegue del scheduler" kubectl rollout status deployment/my-scheduler -n kube-system --timeout=120s; then
        log "ERROR" "Fallo en el despliegue del scheduler - mostrando diagnóstico"

        log "ERROR" "=== Descripción del pod del scheduler ==="
        safe_run "Describir pod del scheduler" kubectl describe pod -n kube-system -l app=my-scheduler

        log "ERROR" "=== Logs del scheduler ==="
        safe_run "Logs del scheduler" kubectl logs -n kube-system -l app=my-scheduler --tail=50

        log "ERROR" "=== Estado de los pods en kube-system ==="
        safe_run "Listar pods de kube-system" kubectl get pods -n kube-system

        return 1
    fi
    
    log "INFO" "Scheduler desplegado exitosamente"
    checkpoint "scheduler_deployed" "Scheduler personalizado desplegado exitosamente"
    return 0
}

# ========================
# Ejecución principal con CHECKPOINTS
# ========================

# ========================
# Ejecución principal con CHECKPOINTS
# ========================

main() {
    log "SUCCESS" "=== INICIO SETUP COMPLETO DEL ENTORNO DE BENCHMARKING ==="
    checkpoint "setup_start" "Iniciando setup completo del entorno"

    # Limpiar imágenes locales y contenedores detenidos
    log "INFO" "Limpiando imágenes y contenedores locales"
    safe_run "Limpiar imágenes locales" docker image rm -f "$CPU_IMAGE" "$RAM_IMAGE" "$SCHED_IMAGE" || true
    safe_run "Limpiar contenedores" docker container prune -f

    # Selección de variante de scheduler
    if ! select_scheduler_variant "$SCHED_IMPL"; then
        log "ERROR" "Fallo en la selección del scheduler"
        return 1
    fi

    # Copiar Dockerfile y requirements al directorio actual ---123-- Si se cambia de directorio esto no sirve (OJO!!!),. HAyq ue ve raahsta que punto sirve esto.
    log "INFO" "Copiando archivos de configuración al directorio actual"
    if ! safe_run "Copiar Dockerfile" cp ../../Dockerfile ./Dockerfile || \
       ! safe_run "Copiar requirements" cp ../../requirements.txt ./requirements.txt || \
       ! safe_run "Copiar RBAC" cp ../../rbac-deploy.yaml ./rbac-deploy.yaml; then
        log "ERROR" "Fallo al copiar archivos de configuración"
        return 1
    fi

    # Crear clúster nuevo
    if ! create_cluster; then
        log "ERROR" "Fallo en la creación del cluster"
        return 1
    fi
    # ✅ REGISTRAR OPERACIÓN: Cluster creado
    register_operation "create_cluster" "kind-cluster"

    # Limpiar namespace y recursos antiguos
    if ! clean_namespace; then
        log "ERROR" "Fallo en la limpieza del namespace"
        return 1
    fi
    # ✅ REGISTRAR OPERACIÓN: Namespace creado
    register_operation "create_namespace" "$NAMESPACE"

    # Construir y cargar imagen del scheduler - SOLO en control-plane
    log "INFO" "Construyendo y cargando imagen del scheduler personalizado"
    if ! load_image_to_cluster "$SCHED_IMAGE" "./" "true"; then
        log "ERROR" "Fallo al cargar imagen del scheduler"
        return 1
    fi

    # ✅ REGISTRAR OPERACIÓN: Imagen del scheduler cargada
    register_operation "load_image_scheduler" "my-py-scheduler"

    # Construir y cargar imágenes basic/nginx/CPU/RAM (SOLO CPU PARA PRUEBAS)
    log "INFO" "Construyendo y cargando imágenes de prueba (solo CPU para pruebas)"
    if ! load_image_to_cluster "$CPU_IMAGE" "./cpu-heavy" "false"; then
        log "ERROR" "Fallo al cargar imagen CPU"
        return 1
    fi
    # ✅ REGISTRAR OPERACIÓN: Imagen de test cargada
    register_operation "load_image_cpu" "cpu-heavy"

    log "INFO" "Construyendo y cargando imágenes de prueba (solo RAM para pruebas)"
    if ! load_image_to_cluster "$RAM_IMAGE" "./ram-heavy" "false"; then
        log "ERROR" "Fallo al cargar imagen CPU"
        return 1
    fi
    # ✅ REGISTRAR OPERACIÓN: Imagen de test cargada
    register_operation "load_image_cpu" "cpu-heavy"

    log "INFO" "Construyendo y cargando imágenes de prueba (Servidor Web pruebas)"
    if ! load_image_to_cluster "$NGINX_IMAGE" "./nginx" "false"; then
        log "ERROR" "Fallo al cargar imagen CPU"
        return 1
    fi
    # ✅ REGISTRAR OPERACIÓN: Imagen de test cargada
    register_operation "load_image_cpu" "nginx"

    log "INFO" "Construyendo y cargando imágenes de prueba (test -basic pause)"
    if ! load_image_to_cluster "$BASIC_IMAGE" "./test-basic" "false"; then
        log "ERROR" "Fallo al cargar imagen CPU"
        return 1
    fi
    # ✅ REGISTRAR OPERACIÓN: Imagen de test cargada
    register_operation "load_image_cpu" "test-basic"

    # Cargamos módulos de métricas
    log "INFO" "Configurando métricas del cluster"
    install_metrics_server  # Si falla, tenemos que parar

    # ✅ REGISTRAR OPERACIÓN: Metrics Server instalado
    register_operation "install_metrics_server" "metrics-server"

    log "INFO" "Mostrando estado actual del cluster"
    show_cluster_info

    # ✅ AUDITORÍA CONTEXTUAL PRE-SCHEDULER
    log "INFO" "🔍 Realizando auditoría PRE-scheduler..."
    if ! audit_cluster_health "pre_scheduler"; then
        log "WARN" "Problemas detectados en la auditoría PRE-scheduler, continuando..."
    fi
    checkpoint "pre_scheduler_audit_done" "Auditoría PRE-scheduler completada"

    log "INFO" "=== ENTORNO COMPLETO LISTO PARA TESTS ==="

    # DESPLEGAMOS SCHEDULER CUSTOM (watch o polling)
    if ! deploy_scheduler "$SCHED_IMPL"; then
        log "ERROR" "Fallo en el despliegue del scheduler"
        return 1
    fi
    log "SUCCESS" "🔍 Desplegando my-scheduler..."
    # ✅ REGISTRAR OPERACIÓN: Scheduler desplegado
    register_operation "deploy_scheduler" "my-scheduler"

    # ✅ AUDITORÍA CONTEXTUAL POST-SCHEDULER
    log "INFO" "🔍 Realizando auditoría POST-scheduler..."
    if ! audit_cluster_health "post_scheduler"; then
        log "ERROR" "Problemas críticos en auditoría POST-scheduler"
        return 1
    fi

    checkpoint "setup_completed" "Setup completo finalizado exitosamente - Listo para tests"
    log "SUCCESS" "=== SETUP COMPLETO FINALIZADO EXITOSAMENTE ==="

    # ✅ EJECUTAR TESTS DESPUÉS DEL SETUP
    log "INFO" "🚀 Iniciando ejecución de tests..."

    # Calcular máximo de pods concurrentes (50% del total o mínimo 5)
    local max_concurrent=$(( NUM_PODS / 2 ))
    if [[ $max_concurrent -lt 5 ]]; then
        max_concurrent=5
    fi

    log "INFO" "Parámetros para tests: Scheduler=$SCHED_IMPL, Pods=$NUM_PODS, Concurrentes=$max_concurrent"

#    if safe_run ./scheduler-test.sh "$SCHED_IMPL" "$NUM_PODS" "$max_concurrent"; then
#        log "SUCCESS" "=== TESTS COMPLETADOS EXITOSAMENTE ==="
#        return 0
#    else
#        local test_exit_code=$?
#        log "ERROR" "Tests fallaron con código: $test_exit_code"
#        return $test_exit_code
#    fi
}

# Ejecutar función principal
main "$@"
