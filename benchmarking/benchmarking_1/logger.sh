#!/bin/bash

# ========================================
# LOGGING Y CONTROL CENTRALIZADO
# ========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
LOG_FILE="$LOG_DIR/benchmarking.log"
CHECKPOINT_FILE="${LOG_DIR}/checkpoints.log"
mkdir -p "$LOG_DIR"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Nivel de log
LOG_LEVEL=${LOG_LEVEL:-4}

# Arrays globales para control
declare -a ALL_BACKGROUND_PIDS=()
declare -a CLUSTER_RESOURCES=()
declare -A CHECKPOINTS=()

# Estado global
ABORTING=false
CURRENT_CHECKPOINT=""

# ========================================
# SISTEMA DE TRACKING DE OPERACIONES
# ========================================

# Array global para trackear operaciones realizadas
declare -A DEPLOYED_RESOURCES=()

# Función para registrar operaciones
register_operation() {
    local operation="$1"
    local resource="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    DEPLOYED_RESOURCES["$operation"]="$resource"
    log "DEBUG" "📝 Operación registrada: $operation -> $resource"
}

# Función para verificar qué operaciones se han realizado
get_deployed_operations() {
    log "DEBUG" "Operaciones realizadas:"
    for op in "${!DEPLOYED_RESOURCES[@]}"; do
        log "DEBUG" "  - $op: ${DEPLOYED_RESOURCES[$op]}"
    done
}

# Función para verificar si una operación fue realizada
is_operation_done() {
    local operation="$1"
    [[ -n "${DEPLOYED_RESOURCES[$operation]:-}" ]]
}

# ========================================
# FUNCIONES DE CHECKPOINTS
# ========================================

checkpoint() {
    local name="$1"
    local message="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    CHECKPOINTS["$name"]="$timestamp"
    CURRENT_CHECKPOINT="$name"

    echo "[$timestamp] CHECKPOINT: $name - $message" >> "$CHECKPOINT_FILE"
    log "INFO" "🔐 CHECKPOINT: $name - $message"
}

rollback_to_checkpoint() {
    local target_checkpoint="$1"
    log "INFO" "🔄 Iniciando rollback al checkpoint: $target_checkpoint"

    # Mostrar operaciones realizadas hasta ahora
    log "DEBUG" "Operaciones realizadas hasta el checkpoint:"
    get_deployed_operations

    case "$target_checkpoint" in
        "cluster_created")
            # Rollback: eliminar cluster
            safe_run kind delete cluster --name sched-lab
            ;;
        "pre_scheduler_audit_done")
            # Rollback: limpiar recursos previos al scheduler
            safe_run kubectl delete deployment my-scheduler -n kube-system --ignore-not-found
            safe_run kubectl delete --all pods --namespace test-scheduler --ignore-not-found
            ;;
        "scheduler_deployed")
            # Rollback: eliminar scheduler y limpiar namespace
            safe_run kubectl delete deployment my-scheduler -n kube-system --ignore-not-found
            safe_run kubectl delete --all pods --namespace test-scheduler --ignore-not-found
            ;;
        "tests_started")
            # Rollback: limpiar pods de test
            safe_run kubectl delete --all pods --namespace test-scheduler --ignore-not-found
            ;;
        "tests_completed"|"reports_generated")
            # Rollback: solo limpiar recursos temporales, mantener reports
            log "INFO" "Checkpoint final - manteniendo reportes generados"
            safe_run kubectl delete --all pods --namespace test-scheduler --ignore-not-found
            ;;
        "pods_test_started")
            # Rollback: limpiar pods de test (para backward compatibility)
            safe_run kubectl delete --all pods --namespace test-scheduler --ignore-not-found
            ;;
        *)
            log "WARN" "Checkpoint desconocido: $target_checkpoint, limpieza general"
            general_cleanup
            ;;
    esac

    log "INFO" "Rollback completado al checkpoint: $target_checkpoint"
}

# ========================================
# FUNCIONES DE CONTROL DE PROCESOS
# ========================================

register_background_pid() {
    local pid=$1
    local description="$2"
    ALL_BACKGROUND_PIDS+=("$pid")
    log "DEBUG" "Registrado PID $pid: $description"
}

kill_all_background_processes() {
    if [ ${#ALL_BACKGROUND_PIDS[@]} -eq 0 ]; then
        return
    fi

    log "INFO" "Deteniendo ${#ALL_BACKGROUND_PIDS[@]} procesos en background..."

    # SIGTERM primero (graceful)
    for pid in "${ALL_BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done

    # Esperar 2 segundos
    sleep 2

    # SIGKILL si es necesario
    for pid in "${ALL_BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            log "DEBUG" "Forzando terminación de PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done

    ALL_BACKGROUND_PIDS=()
    log "INFO" "Todos los procesos background detenidos"
}

# ========================================
# FUNCIONES DE AUDITORÍA INTELIGENTE DEL CLUSTER
# ========================================

wait_for_nodes_ready() {
    log "DEBUG" "Esperando a que todos los nodos estén Ready..."
    local timeout=60
    local elapsed=0

    while true; do
        local ready_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True)
        local total_nodes=$(kubectl get nodes -o name | wc -l)

        if [ "$ready_nodes" -eq "$total_nodes" ]; then
            log "INFO" "✅ Todos los nodos están Ready ($ready_nodes/$total_nodes)"
            return 0
        fi

        if [ "$elapsed" -ge "$timeout" ]; then
            log "ERROR" "⏰ Timeout: solo $ready_nodes de $total_nodes nodos están Ready tras ${timeout}s"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done
}

# Ejecuta un comando con reintentos controlados
retry_command() {
    local cmd="$1"
    local max_retries="${2:-3}"
    local delay="${3:-5}"
    local attempt=1

    while true; do
        log "DEBUG" "Intento $attempt/$max_retries → $cmd"
        if eval "$cmd" &>/dev/null; then
            log "INFO" "Comando OK: $cmd"
            return 0
        fi

        if [ "$attempt" -ge "$max_retries" ]; then
            log "ERROR" "Fallo persistente tras $max_retries intentos: $cmd"
            return 1
        fi

        log "WARN" "Fallo en intento $attempt, reintentando en ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

# Auditoría inteligente basada en contexto
audit_cluster_health() {
    local context="${1:-full}"
    log "INFO" "🔍 Iniciando auditoría del cluster (contexto: $context)"

    local audit_passed=true

   # Siempre verificar nodos y control plane básico
    if ! audit_basic_infrastructure; then
        log "ERROR" "Infraestructura básica no saludable"
        return 1
    fi

    # Verificar según el contexto y operaciones realizadas
    case "$context" in
        "pre_scheduler")
            audit_pre_scheduler
            ;;
        "post_scheduler") 
            audit_post_scheduler
            ;;
        "post_tests")
            audit_post_tests
            ;;
        "full")
            audit_full_cluster
            ;;
        *)
            log "WARN" "Contexto de auditoría desconocido: $context, usando full"
            audit_full_cluster
            ;;
    esac
    
    if [ "$audit_passed" = true ]; then
        log "INFO" "✅ Auditoría completada - Estado: HEALTHY"
        return 0
    else
        log "ERROR" "❌ Auditoría completada - Estado: UNHEALTHY"
        return 1
    fi
}

audit_basic_infrastructure() {
    log "DEBUG" "Verificando infraestructura básica..."
    
    # 1. Verificar nodos
    if ! wait_for_nodes_ready; then
        log "ERROR" "Nodos no Ready"
        return 1
    fi

    # 2. Verificar componentes del control plane
    local components=("etcd" "kube-apiserver" "kube-controller-manager" "kube-scheduler")
    for component in "${components[@]}"; do
        if ! retry_command "kubectl get pods -n kube-system -l component=$component --field-selector=status.phase=Running" 3 5; then
            log "ERROR" "Componente $component no está operativo"
            return 1
        fi
    done
    
    return 0
}

audit_pre_scheduler() {
    log "DEBUG" "Auditoría PRE-scheduler - verificando prerequisitos..."
    
    # Verificar que las imágenes estén cargadas (si se registró la operación)
    if is_operation_done "load_image_scheduler"; then
        log "DEBUG" "Verificando imagen my-py-scheduler..."
        if ! verify_scheduler_image_loaded; then
            log "WARN" "Imagen del scheduler no encontrada en nodos"
        fi
    fi
    
    if is_operation_done "load_image_cpu"; then
        log "DEBUG" "Verificando imagenes propias para el test ..."
        if ! verify_test_images_loaded; then
            log "WARN" "Algunas imágenes de test no encontradas"
        fi
    fi
    
    # Verificar metrics-server si se instaló
    if is_operation_done "install_metrics_server"; then
        log "DEBUG" "Verificando metrics-server..."
        if ! verify_metrics_server; then
            log "WARN" "Metrics-server no está operativo"
        fi
    fi
    
    # Verificar namespace de test
    if is_operation_done "create_namespace"; then
        log "DEBUG" "Verificando namespace de test..."
        if ! verify_test_namespace; then
            log "ERROR" "Namespace de test no existe"
            return 1
        fi
    fi
    
    return 0
}

audit_post_scheduler() {
    log "DEBUG" "Auditoría POST-scheduler - verificando despliegue..."
    
    # Verificar que el scheduler esté desplegado y funcionando
    if ! verify_scheduler_deployment; then
        log "ERROR" "Scheduler personalizado no está operativo"
        return 1
    fi
    
    # Verificar que el scheduler esté programando pods
    if ! verify_scheduler_functionality; then
        log "WARN" "Scheduler no está programando pods correctamente"
    fi
    
    return 0
}

audit_post_tests() {
    log "DEBUG" "Auditoría POST-tests - verificando resultados..."
    
    # Verificar que se completaron los tests
    if ! verify_tests_completed; then
        log "WARN" "No todos los tests se completaron exitosamente"
    fi
    
    # Verificar que se generaron métricas
    if ! verify_metrics_generated; then
        log "WARN" "No se generaron todas las métricas esperadas"
    fi
    
    return 0
}

audit_full_cluster() {
    log "DEBUG" "Auditoría COMPLETA del cluster..."
    
    audit_pre_scheduler || return 1
    audit_post_scheduler || return 1
    audit_post_tests || return 1
    
    return 0
}

# ========================================
# FUNCIONES ESPECÍFICAS DE VERIFICACIÓN
# ========================================

verify_scheduler_image_loaded() {
    log "DEBUG" "Verificando imagen del scheduler SOLO en control-plane..."
    local image_exists=true

    # Solo verificar en control-plane
    for node in $(kind get nodes --name sched-lab | grep control-plane); do
        if docker exec "$node" crictl images | grep -q "my-py-scheduler"; then
            log "DEBUG" "✅ Imagen my-py-scheduler encontrada en $node"
        else
            log "DEBUG" "❌ Imagen my-py-scheduler NO encontrada en $node"
            image_exists=false
        fi
    done

    $image_exists
}

verify_test_images_loaded() {
    log "DEBUG" "Verificando imágenes de test en workers (método simple)..."

    local nodes=$(kind get nodes --name sched-lab | grep worker)

    if [ -z "$nodes" ]; then
        log "ERROR" "No se encontraron nodos workers"
        return 1
    fi
    local test_images=("cpu-heavy" "ram-heavy" "nginx" "pause")
    local all_images_loaded=true

    for node in $nodes; do
        log "DEBUG" "Verificando imágenes en $node:"

        # Obtener la lista de imágenes UNA sola vez por nodo
        local node_images
        node_images=$(docker exec "$node" crictl images)
        if [ $? -ne 0 ]; then
            log "ERROR" "Error al obtener imágenes del nodo $node"
            all_images_loaded=false
            continue
        fi

        # Verificar cada imagen en la lista descargada
        for image in "${test_images[@]}"; do
            if echo "$node_images" | grep -q "$image"; then
                log "DEBUG" "✅ $image encontrada en $node"
            else
                log "DEBUG" "❌ $image NO encontrada en $node"
                all_images_loaded=false
            fi
        done

    done

    if $all_images_loaded; then
        log "INFO" "✅ Todas las imágenes de test encontradas en workers"
    else
        log "WARN" "⚠️ Algunas imágenes de test no encontradas en workers"
    fi

    return $([ "$all_images_loaded" = true ] && echo 0 || echo 1)
}

verify_metrics_server() {
    log "DEBUG" "Verificando metrics-server..."
    
    # Verificar que el deployment existe
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        log "DEBUG" "Metrics Server no está instalado"
        return 1
    fi
    
    # Verificar que esté disponible
    if ! kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=30s &>/dev/null; then
        log "WARN" "Metrics Server no está disponible"
        return 1
    fi
    
    # Verificar que la API responde
    if kubectl top nodes --no-headers &>/dev/null; then
        log "DEBUG" "✅ Metrics Server operativo"
        return 0
    else
        log "WARN" "Metrics Server instalado pero la API no responde"
        return 1
    fi
}

verify_test_namespace() {
    kubectl get namespace test-scheduler &>/dev/null
}

verify_scheduler_deployment() {
    log "DEBUG" "Verificando despliegue del scheduler personalizado..."
    
    # Verificar que el deployment existe
    if ! kubectl get deployment my-scheduler -n kube-system &>/dev/null; then
        log "ERROR" "Deployment my-scheduler no encontrado"
        return 1
    fi
    
    # Verificar que el pod está running
    if ! kubectl wait --for=condition=ready pod -l app=my-scheduler -n kube-system --timeout=30s &>/dev/null; then
        log "ERROR" "Pod del scheduler no está ready"
        return 1
    fi
    
    # Verificar que el pod está en control-plane (donde debe estar)
    local scheduler_node=$(kubectl get pod -n kube-system -l app=my-scheduler -o jsonpath='{.items[0].spec.nodeName}')
    if [[ "$scheduler_node" == *"control-plane"* ]]; then
        log "DEBUG" "✅ Scheduler ejecutándose en control-plane: $scheduler_node"
    else
        log "WARN" "Scheduler ejecutándose en nodo inesperado: $scheduler_node"
    fi
    
    # Verificar logs del scheduler
    local scheduler_pod=$(kubectl get pods -n kube-system -l app=my-scheduler -o name | head -1 | sed 's#pod/##')
    if [[ -n "$scheduler_pod" ]]; then
        local logs=$(kubectl logs "$scheduler_pod" -n kube-system --tail=10 2>/dev/null)
        if echo "$logs" | grep -q -i "error\|exception\|fail"; then
            log "WARN" "Se detectaron errores en los logs del scheduler"
        fi
    fi
    
    return 0
}

verify_scheduler_functionality() {
    log "DEBUG" "Verificando funcionalidad del scheduler..."
    
    # Crear un pod de test simple para verificar que el scheduler lo programa
    local test_pod="test-scheduler-functionality-$(date +%s)"
    cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $test_pod
  namespace: test-scheduler
spec:
  containers:
  - name: test
    image: pause:3.9
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
        cpu: "100m"
  schedulerName: my-scheduler
EOF

    # Esperar a que se programe
    sleep 5
    
    local scheduled=$(kubectl get pod "$test_pod" -n test-scheduler -o jsonpath='{.spec.schedulerName}' 2>/dev/null)
    local status=$(kubectl get pod "$test_pod" -n test-scheduler -o jsonpath='{.status.phase}' 2>/dev/null)
    
    # Limpiar el pod de test
    kubectl delete pod "$test_pod" -n test-scheduler --ignore-not-found=true &>/dev/null
    
    if [[ "$scheduled" == "my-scheduler" ]]; then
        log "DEBUG" "✅ Scheduler está programando pods correctamente"
        return 0
    else
        log "WARN" "Scheduler no está programando pods (schedulerName: $scheduled)"
        return 1
    fi
}
verify_tests_completed() {
    # Esta función se implementará en scheduler-test.sh
    # Por ahora retorna true para no bloquear la ejecución
    return 0
}

verify_metrics_generated() {
    # Esta función se implementará en scheduler-test.sh  
    # Por ahora retorna true para no bloquear la ejecución
    return 0
}

# ========================================
# FUNCIONES DE LIMPIEZA
# ========================================

cluster_cleanup() {
    log "INFO" "🧹 Limpieza completa del cluster..."

    # 1. Limpiar todos los pods de test
    safe_run kubectl delete --all pods --namespace test-scheduler --ignore-not-found=true --wait=false
    safe_run kubectl delete --all deployments --namespace test-scheduler --ignore-not-found=true --wait=false

    # 2. Limpiar scheduler personalizado
    safe_run kubectl delete deployment my-scheduler -n kube-system --ignore-not-found=true --wait=false
    safe_run kubectl delete -f rbac-deploy.yaml --ignore-not-found=true --wait=false

    # 3. Limpiar metrics server
    safe_run kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml --ignore-not-found=true

    # 4. Esperar a que se completen las eliminaciones
    sleep 5

    log "INFO" "✅ Limpieza del cluster completada"
}

general_cleanup() {
    log "INFO" "🚮 Ejecutando limpieza general..."

    # 1. Matar todos los procesos background
    kill_all_background_processes

    # 2. Limpiar cluster
    cluster_cleanup

    # 3. Limpiar archivos temporales
    find . -name "temp_*" -type d -mtime +1 -exec rm -rf {} \; 2>/dev/null || true

    log "INFO" "✅ Limpieza general completada"
}

# ========================================
# MANEJO CENTRALIZADO DE SEÑALES
# ========================================

setup_global_trap_handler() {
    log "DEBUG" "Configurando manejo global de señales..."

    # Limpiar traps existentes
    trap - SIGINT SIGTERM EXIT

    # Trap global único
    trap '
        if [ "$ABORTING" = false ]; then
            ABORTING=true
            echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [INFO] 🛑 Señal recibida - Iniciando parada controlada..."
            general_cleanup
            exit 130
        fi
    ' SIGINT SIGTERM

    # Trap para EXIT (siempre se ejecuta al salir)
    trap '
        exit_code=$?
        if [ $exit_code -ne 0 ] && [ "$ABORTING" = false ]; then
            log "ERROR" "Script terminado con error: $exit_code"
            rollback_to_checkpoint "$CURRENT_CHECKPOINT"
        fi
        general_cleanup
    ' EXIT
}

# ========================================
# FUNCIONES DE LOGGING (existentes)
# ========================================

log() {
    local level=$1
    shift
    local msg="$*"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"

    case "$level" in
        DEBUG)
            [[ $LOG_LEVEL -ge 4 ]] && echo -e "${BLUE}[$timestamp] [DEBUG] $msg${NC}"
            ;;
        INFO)
            [[ $LOG_LEVEL -ge 3 ]] && echo "[$timestamp] [INFO] $msg"
            ;;
        WARN)
            [[ $LOG_LEVEL -ge 2 ]] && echo -e "${YELLOW}[$timestamp] [WARN] $msg${NC}"
            ;;
        ERROR)
            [[ $LOG_LEVEL -ge 1 ]] && echo -e "${RED}[$timestamp] [ERROR] $msg${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[$timestamp] [SUCCESS] $msg${NC}"
            ;;
        *)
            [[ $LOG_LEVEL -ge 3 ]] && echo "[$timestamp] [INFO] $msg"
            ;;
    esac
}

safe_run() {
    local command_description=""
    local actual_command=()

    # Detectar si el primer argumento es una descripción (contiene espacios o no es un comando)
    if [[ "$1" == *" "* || ! $(command -v "$1" 2>/dev/null) ]]; then
        command_description="$1"
        shift
    fi

    # Construir el comando real
    actual_command=("$@")

    log "DEBUG" "Ejecutando: ${actual_command[*]}"

    # Ejecutar el comando real
    if "${actual_command[@]}"; then
        if [[ -n "$command_description" ]]; then
            log "DEBUG" "Comando exitoso: $command_description"
        else
            log "DEBUG" "Comando exitoso: ${actual_command[*]}"
        fi
        return 0
    else
        local exit_code=$?
        if [[ -n "$command_description" ]]; then
            log "WARN" "Comando falló ($exit_code): $command_description"
        else
            log "WARN" "Comando falló ($exit_code): ${actual_command[*]}"
        fi
        return $exit_code
    fi
}

enable_error_trapping() {
    set -eE -o pipefail
    trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR
}

error_handler() {
    local line=$1
    local command=$2
    local exit_code=$3

    # No manejar errores si ya estamos abortando
    [ "$ABORTING" = true ] && exit $exit_code

    log "ERROR" "❌ ERROR en línea $line: '$command' (code: $exit_code)"
    log "ERROR" "Checkpoint actual: $CURRENT_CHECKPOINT"

    # Rollback al último checkpoint
    rollback_to_checkpoint "$CURRENT_CHECKPOINT"

    exit $exit_code
}

# Inicialización global
log "DEBUG" "🔧 Logger inicializado - Log: $LOG_FILE"
setup_global_trap_handler
