#!/bin/bash
set -euo pipefail

# ========================================
# CONFIGURACIÓN GLOBAL
# ========================================
SCHED_IMPL=${1:-polling}
NUM_PODS=${2:-20}
MAX_CONCURRENT_PODS=${3:-5}
NAMESPACE="test-scheduler"
SCHEDULER_NAME="my-scheduler"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Capturar SIGINT y SIGTERM
trap abort_all SIGINT SIGTERM

# ========================================
# CARGAR LOGGING Y MANEJO DE ERRORES
# ========================================
source ./logger.sh
enable_error_trapping

# Estructura de directorios
BASE_DIR="./${SCHED_IMPL}"
METRICS_DIR="${BASE_DIR}/metrics"
TEMP_DIR="${BASE_DIR}/temp_${TIMESTAMP}"
RESULTS_JSON="${METRICS_DIR}/scheduler_metrics_${TIMESTAMP}.json"
POD_TYPES=("cpu-heavy" "ram-heavy" "nginx" "test-basic")

# Variables para control de ejecución
declare -A CURRENT_PODS=()
declare -a ALL_BACKGROUND_PIDS=()

# ========================================
# FUNCIÓN SAFE_RUN
# ========================================
# La voy a pasar a logger
# ==========================
# safe_run() {
#     "$@" || log "WARN" "Comando '$*' falló pero se ignora"
# }


# ========================================
# FUNCIONES DE CONTROL DE EJECUCIÓN
# ========================================


# Registrar un pod activo
register_pod() {
    local pod_name=$1
    CURRENT_PODS["$pod_name"]=1
    log "DEBUG" "Pod registrado: $pod_name (total: ${#CURRENT_PODS[@]})"
}

# Limpiar todos los pods activos
cleanup_active_pods() {
    if [ ${#CURRENT_PODS[@]} -gt 0 ]; then
        log "INFO" "Limpiando ${#CURRENT_PODS[@]} pods activos..."
        for pod in "${!CURRENT_PODS[@]}"; do
            log "DEBUG" "Eliminando pod: $pod"
            safe_run kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found=true --force --grace-period=0
        done
        CURRENT_PODS=()
    fi
}

# Limpiar namespace
clean_namespace() {
    log "INFO" "Limpiando namespace $NAMESPACE"
    safe_run kubectl delete pods --all -n "$NAMESPACE" --ignore-not-found=true --wait=false
    sleep 2
}

# ========================================
# INICIALIZACIÓN
# ========================================
initialize_test() {
    log "INFO" "Inicializando test de scheduler: $SCHED_IMPL"
    log "INFO" "Número de pods por tipo: $NUM_PODS"
    log "INFO" "Máximo pods concurrentes: $MAX_CONCURRENT_PODS"
    log "INFO" "Namespace: $NAMESPACE"

    # Limpieza de temporales antiguos (>3 días)
    find "$BASE_DIR" -type d -name 'temp_*' -mtime +3 -exec rm -rf {} \; 2>/dev/null || true

    # Crear estructura de directorios organizada por scheduler
    mkdir -p "$BASE_DIR" "$METRICS_DIR" "$TEMP_DIR"
    log "DEBUG" "Directorios creados para scheduler '$SCHED_IMPL':"
    log "DEBUG" "  - Base: $BASE_DIR"
    log "DEBUG" "  - Métricas: $METRICS_DIR"
    log "DEBUG" "  - Temporal: $TEMP_DIR"
}

# ========================================
# FUNCIONES DE MÉTRICAS
# ========================================

clean_numeric_value() {
    local value="$1"
    [[ -z "$value" || "$value" == "N/A" ]] && echo "0" && return
    echo "$value" | tr -d '\n\r\t ' | sed 's/[^0-9.]//g'
}
get_pull_start_latency() {
    local pod_name=$1
    local namespace=$2
    log "DEBUG" "Calculando pull_start_latency para pod: $pod_name"

    # Obtener eventos con manejo de errores
    local events_json
    if ! events_json=$(kubectl get events -n "$namespace" \
        --field-selector "involvedObject.name=$pod_name" \
        --sort-by='.lastTimestamp' -o json 2>/dev/null); then
        log "WARN" "No se pudieron obtener eventos para el pod $pod_name"
        echo "N/A"
        return 1
    fi

    # Extraer timestamps de eventos Pulling y Started
    local pulling_ts started_ts

    pulling_ts=$(echo "$events_json" | jq -r '.items[] | select(.reason=="Pulling") | .lastTimestamp' | head -1)
    started_ts=$(echo "$events_json" | jq -r '.items[] | select(.reason=="Started") | .lastTimestamp' | head -1)

    if [[ -z "$pulling_ts" || "$pulling_ts" == "null" ]]; then
        log "DEBUG" "No se encontró evento Pulling para $pod_name"
        echo "N/A"
        return 1
    fi

    if [[ -z "$started_ts" || "$started_ts" == "null" ]]; then
        log "DEBUG" "No se encontró evento Started para $pod_name"
        echo "N/A"
        return 1
    fi

    # Convertir timestamps a segundos desde epoch
    local pulling_sec started_sec latency

    if ! pulling_sec=$(date -d "$pulling_ts" +%s 2>/dev/null); then
        log "WARN" "No se pudo parsear timestamp Pulling: $pulling_ts"
        echo "N/A"
        return 1
    fi

    if ! started_sec=$(date -d "$started_ts" +%s 2>/dev/null); then
        log "WARN" "No se pudo parsear timestamp Started: $started_ts"
        echo "N/A"
        return 1
    fi

    # Calcular latencia
    latency=$((started_sec - pulling_sec))

    if [[ $latency -lt 0 ]]; then
        log "WARN" "Latencia negativa para $pod_name: $latency segundos (Pulling: $pulling_ts, Started: $started_ts)"
        echo "N/A"
        return 1
    fi

    log "DEBUG" "Pull_start_latency para $pod_name: $latency segundos"
    echo "$latency"
    return 0
}

get_pending_running_latency() {
    local pod_name=$1
    local namespace=$2
    log "DEBUG" "Calculando pending_running_latency para pod: $pod_name"

    # Primero verificar que el pod esté running
    local pod_phase
    pod_phase=$(kubectl -n "$namespace" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ $? -ne 0 || "$pod_phase" != "Running" ]]; then
        log "WARN" "Pod $pod_name no está en fase Running (fase: ${pod_phase:-No encontrado})"
        echo "N/A"
        return 1
    fi

    local creation_time #instante en que el API Server registra el objeto Pod en etcd (t clúster).
    creation_time=$(kubectl -n "$namespace" get pod "$pod_name" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    if [[ $? -ne 0 || -z "$creation_time" ]]; then
        log "WARN" "No se pudo obtener creationTimestamp para $pod_name"
        echo "N/A"
        return 1
    fi

    local start_time # momento en que el contenedor del Pod arranca y comienza su ejecución (t Pod).
    start_time=$(kubectl -n "$namespace" get pod "$pod_name" -o jsonpath='{.status.startTime}' 2>/dev/null)
    if [[ $? -ne 0 || -z "$start_time" ]]; then
        log "WARN" "No se pudo obtener startTime para $pod_name"
        echo "N/A"
        return 1
    fi

   # Convertir tiempos a segundos con validación
    local creation_sec start_sec
    if ! creation_sec=$(date -d "$creation_time" +%s 2>/dev/null); then
        log "WARN" "No se pudo parsear creationTime: $creation_time"
        echo "N/A"
        return 1
    fi

    if ! start_sec=$(date -d "$start_time" +%s 2>/dev/null); then
        log "WARN" "No se pudo parsear startTime: $start_time"
        echo "N/A"
        return 1
    fi

    # Validar que start_time sea posterior a creation_time
    if [[ $start_sec -lt $creation_sec ]]; then
        log "WARN" "startTime anterior a creationTime para $pod_name"
        echo "N/A"
        return 1
    fi

    local latency=$((start_sec - creation_sec))

    # Validar latencia razonable (menos de 1 hora = 3600 segundos)
    if [[ $latency -gt 3600 ]]; then
        log "WARN" "Latencia muy alta para $pod_name: $latency segundos"
    fi

    log "DEBUG" "Pending_running_latency para $pod_name: $latency segundos"
    echo "$latency"
    return 0
}

get_scheduler_resources_avg() {
    log "DEBUG" "Calculando uso promedio de recursos del scheduler" >&2
    
    local cpu_sum=0 mem_sum=0 samples=0
    local scheduler_pod

    scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')
    if [[ -z "$scheduler_pod" ]]; then
        log "WARN" "No se pudo obtener scheduler_pod" >&2
        echo "0 0"
        return 1
    fi

    for i in {1..3}; do
        local top_output cpu mem
        
        if top_output=$(kubectl top pod "$scheduler_pod" -n kube-system 2>/dev/null); then
            cpu=$(echo "$top_output" | awk 'NR==2 {print $2}' | sed 's/m//')
            mem=$(echo "$top_output" | awk 'NR==2 {print $3}' | sed 's/Mi//')

            if [[ "$cpu" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]]; then
                cpu_sum=$((cpu_sum + cpu))
                mem_sum=$((mem_sum + mem))
                samples=$((samples + 1))
            fi
        fi
        sleep 1
    done

    if [[ $samples -gt 0 ]]; then
        local avg_cpu=$((cpu_sum / samples))
        local avg_mem=$((mem_sum / samples))
        echo "$avg_cpu $avg_mem"
    else
        echo "0 0"
    fi
    
    return 0
}
get_list_ops() {
    local pod_name=$1
    log "DEBUG" "Calculando list_ops para pod: $pod_name"

    # Obtener scheduler pod con mejor manejo de errores
    local scheduler_pod
    if ! scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); then
        log "WARN" "No se pudo obtener scheduler_pod para $SCHEDULER_NAME"
        echo "0"
        return 1
    fi

    # Contar ocurrencias en los últimos 10 segundos
    local count=0
    if kubectl_output=$(kubectl -n kube-system logs "$scheduler_pod" --since=10s 2>/dev/null); then
        count=$(echo "$kubectl_output" | grep -c "$pod_name" 2>/dev/null || echo "0")
    else
        log "WARN" "No se pudieron obtener logs del pod $scheduler_pod"
        echo "0"
        return 1
    fi

    local list_ops=$count
    [[ $list_ops -lt 0 ]] && list_ops=0

    log "DEBUG" "List_ops para $pod_name: $list_ops"
    echo "$list_ops"
    return 0
}

get_scheduler_attempts_events() {
    local pod_name=$1
    log "DEBUG" "Calculando attempts y eventos para pod: $pod_name"

    # Obtener scheduler pod de forma más robusta
    local scheduler_pod
    scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ $? -ne 0 || -z "$scheduler_pod" ]]; then
        log "WARN" "No se pudo obtener scheduler_pod para $SCHEDULER_NAME"
        echo "0 0 0"
        return 1
    fi

    log "DEBUG" "Usando scheduler pod: $scheduler_pod"

    # Obtener logs una sola vez
    local logs
    logs=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null)
    if [[ $? -ne 0 || -z "$logs" ]]; then
        log "WARN" "No se pudieron obtener logs del scheduler pod $scheduler_pod"
        echo "0 0 0"
        return 1
    fi

    # Patrón de búsqueda para el pod específico (namespace/name)
    local pod_pattern="$NAMESPACE/$pod_name"

    # Contar attempts
    local total_attempts
    total_attempts=$(echo "$logs" | grep -c "Attempting to schedule pod: $pod_pattern" || echo "0")
    total_attempts=$(clean_numeric_value "$total_attempts")

    # Contar successes
    local successful
    successful=$(echo "$logs" | grep -c "Bound $pod_pattern" || echo "0")
    successful=$(clean_numeric_value "$successful")

    # Calcular implicit_retries
    local implicit_retries=0
    if [[ $total_attempts -gt 0 && $successful -gt 0 ]]; then
        implicit_retries=$((total_attempts - successful))
        [[ $implicit_retries -lt 0 ]] && implicit_retries=0
    elif [[ $total_attempts -gt 0 ]]; then
        implicit_retries=$total_attempts
    fi

    # Contar retries (solo líneas que mencionen el pod Y tengan patrones de retry/error)
    local retries
    retries=$(echo "$logs" | grep "$pod_pattern" | grep -E "retry|Retry|error|Error" | wc -l || echo "0")
    retries=$(clean_numeric_value "$retries")

    # Contar events de scheduling
    local events
    events=$(echo "$logs" | grep -E "Bound.*$pod_pattern|Scheduled.*$pod_pattern" | wc -l || echo "0")
    events=$(clean_numeric_value "$events")

    log "DEBUG" "Métricas scheduler para $pod_name: attempts=$total_attempts, successful=$successful, retries=$retries, implicit_retries=$implicit_retries, events=$events"
    echo "$retries $implicit_retries $events"
    return 0
}
# ========================================
# FUNCIONES DE POD
# ========================================

wait_for_pod_ready() {
    local pod_name=$1
    local namespace=$2
    local timeout=120
    local counter=0

    log "DEBUG" "Esperando a que pod $pod_name esté Ready..."

    while [ $counter -lt $timeout ]; do
        local pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        case $pod_status in
            "Running")
                # Verificar si todos los contenedores están ready
                local ready=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
                if [ "$ready" = "true" ]; then
                    log "INFO" "Pod $pod_name está Ready y operativo"
                    return 0
                fi
                ;;
            "Succeeded"|"Failed")
                log "WARN" "Pod $pod_name terminó con estado: $pod_status"
                return 1
                ;;
            "NotFound")
                log "WARN" "Pod $pod_name no encontrado"
                return 1
                ;;
        esac

        sleep 2
        counter=$((counter + 2))
        log "DEBUG" "Esperando pod $pod_name... ($counter/${timeout}s)"
    done

    log "WARN" "Timeout esperando por pod $pod_name"
    return 1
}

write_pod_metrics_to_temp() {
    local pod_name=$1 pod_type=$2 latency=$3 pending_latency=$4 pull_latency=$5 cpu=$6 mem=$7 \
          list_ops=$8 retries=$9 implicit_retries=${10} events=${11}

    local temp_file="${TEMP_DIR}/${pod_name}.json"
    log "DEBUG" "Escribiendo métricas temporales en: $temp_file"

    safe_run jq -n \
        --arg pod_name "$pod_name" \
        --arg pod_type "$pod_type" \
        --argjson latency "$latency" \
        --argjson pending_latency "$pending_latency" \
        --argjson pull_latency "$pull_latency" \
        --argjson cpu "$cpu" \
        --argjson mem "$mem" \
        --argjson list_ops "$list_ops" \
        --argjson retries "$retries" \
        --argjson implicit_retries "$implicit_retries" \
        --argjson events "$events" \
        '{
            pod_name: $pod_name,
            pod_type: $pod_type,
            scheduling_latency_seconds: $latency,
            latency_pending_running_seconds: $pending_latency,
            pull_start_latency_seconds: $pull_latency,
            scheduler_cpu_millicores: $cpu,
            scheduler_memory_mib: $mem,
            list_ops: $list_ops,
            retries: $retries,
            implicit_retries: $implicit_retries,
            events: $events,
            timestamp: now | todate
        }' > "$temp_file"

    if [[ $? -eq 0 ]]; then
        log "DEBUG" "Métricas JSON escritas exitosamente en $temp_file"
    else
        log "ERROR" "Error al escribir métricas JSON en $temp_file"
    fi
}
# Función para crear pods de forma robusta
create_pod_safely() {
    local yaml_file="$1"
    local namespace="$2"
    
    log "DEBUG" "Creando pod desde: $yaml_file" >&2
    
    # Crear pod y capturar SOLO el nombre
    local pod_name
    pod_name=$(kubectl create -f "$yaml_file" -n "$namespace" -o jsonpath='{.metadata.name}' 2>/dev/null)
    
    if [[ $? -ne 0 || -z "$pod_name" ]]; then
        log "ERROR" "Error al crear pod desde $yaml_file" >&2
        return 1
    fi
    
    # Devolver SOLO el nombre del pod por stdout
    echo "$pod_name"
    return 0
}
# Función para obtener métricas numéricas de forma segura
get_numeric_metric() {
    local metric_value="$1"
    local default="${2:-0}"
    
    # Si es "N/A" o vacío, usar valor por defecto
    if [[ "$metric_value" == "N/A" || -z "$metric_value" ]]; then
        echo "$default"
        return 0
    fi
    
    # Extraer solo números y puntos decimales
    local numeric_value
    numeric_value=$(echo "$metric_value" | sed 's/[^0-9.]//g')
    
    # Si no queda nada, usar valor por defecto
    if [[ -z "$numeric_value" ]]; then
        echo "$default"
        return 0
    fi
    
    echo "$numeric_value"
    return 0
}

# Función principal de medición corregida
measure_and_save_pod_metrics() {
    local base_pod_name="$1" pod_type="$2" yaml_file="$3" namespace="$4"

    # TODOS los logs van a stderr para no interferir con stdout
    log "DEBUG" "Iniciando medición para: $base_pod_name, tipo: $pod_type" >&2

    local t0=$(date +%s)
    
    # Crear pod de forma segura
    local pod_name
    pod_name=$(create_pod_safely "$yaml_file" "$namespace")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    log "INFO" "Pod creado: $pod_name" >&2
    register_pod "$pod_name"

    # Esperar a que el pod esté listo
    if ! wait_for_pod_ready "$pod_name" "$namespace" 120; then
        log "WARN" "Pod $pod_name no alcanzó estado Ready" >&2
    fi

    sleep 2

    # Calcular métricas con manejo seguro de valores
    local latency=$(( $(date +%s) - t0 ))
    
    # Obtener métricas con valores por defecto para "N/A"
    local pending_latency=$(get_pending_running_latency "$pod_name" "$namespace")
    pending_latency=$(get_numeric_metric "$pending_latency" 0)
    
    local pull_latency=$(get_pull_start_latency "$pod_name" "$namespace")  
    pull_latency=$(get_numeric_metric "$pull_latency" 0)
    
    local scheduler_resources
    scheduler_resources=$(get_scheduler_resources_avg)
    local cpu mem
    read -r cpu mem <<< "$scheduler_resources"
    cpu=$(get_numeric_metric "$cpu" 0)
    mem=$(get_numeric_metric "$mem" 0)
    
    local list_ops=$(get_list_ops "$pod_name")
    list_ops=$(get_numeric_metric "$list_ops" 0)
    
    local attempts_result
    attempts_result=$(get_scheduler_attempts_events "$pod_name")
    local retries implicit_retries events
    read -r retries implicit_retries events <<< "$attempts_result"
    retries=$(get_numeric_metric "$retries" 0)
    implicit_retries=$(get_numeric_metric "$implicit_retries" 0)
    events=$(get_numeric_metric "$events" 0)

    # Escribir métricas
    write_pod_metrics_to_temp "$pod_name" "$pod_type" "$latency" "$pending_latency" "$pull_latency" \
        "$cpu" "$mem" "$list_ops" "$retries" "$implicit_retries" "$events"

    # Limpiar
    safe_run kubectl delete pod "$pod_name" -n "$namespace" --ignore-not-found=true --wait=false
    unset CURRENT_PODS["$pod_name"]

    log "INFO" "Medición completada para: $pod_name" >&2
    return 0
}


#=========================================
# Función pñara abortar todo
#======================================
abort_all() {
    log "INFO" "🛑 SE RECIBIÓ Ctrl+C, ABORTANDO EJECUCIÓN PR EL USER..."
    
    # 1. Matar TODOS los procesos en background
    log "INFO" "Matando ${#ALL_BACKGROUND_PIDS[@]} trabajos en background..."
    for pid in "${ALL_BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            log "DEBUG" "Enviando SIGTERM al proceso $pid"
            kill "$pid" 2>/dev/null
        fi
    done
    
    # 2. Esperar un poco para terminación graceful
    sleep 3
    
    # 3. Forzar terminación si aún existen
    for pid in "${ALL_BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            log "DEBUG" "Forzando terminación del proceso $pid"
            kill -9 "$pid" 2>/dev/null
        fi
    done
    
    # 4. Limpiar recursos de Kubernetes
    cleanup_active_pods
    
    log "INFO" "Abortado completado. Saliendo..."
    exit 1
}
# ======================================== 
process_pod() {
    local base_pod_name="$1"
    local pod_type="$2"
    local yaml_file="$3"
    local namespace="$4"
    
    log "DEBUG" "Procesando pod: $base_pod_name"
    
    if [[ ! -f "$yaml_file" ]]; then
        log "ERROR" "YAML no encontrado: $yaml_file"
        return 1
    fi
    
    measure_and_save_pod_metrics "$base_pod_name" "$pod_type" "$yaml_file" "$namespace"
}


# Función para procesar pods en paralelo de forma segura
run_all_tests_parallel() {
    log "INFO" "Ejecución paralela iniciada (máximo $MAX_CONCURRENT_PODS pods)" >&2
    local total_jobs=0
    local job_count=0

    # Usar un fifo para control de concurrencia
    local fifo_path="${TEMP_DIR}/concurrency.fifo"
    mkfifo "$fifo_path"
    exec 3<> "$fifo_path"
    
    # Inicializar el fifo con slots
    for ((i=0; i<MAX_CONCURRENT_PODS; i++)); do
        echo >&3
    done

    for pod_type in "${POD_TYPES[@]}"; do
        for i in $(seq 1 "$NUM_PODS"); do
            local base_pod_name="${pod_type}-pod-${i}"
            local yaml_file="./${pod_type}/${pod_type}-pod.yaml"

            # Esperar slot disponible
            read -u 3 -r
            
            (
                log "DEBUG" "Iniciando job para: $base_pod_name" >&2
                
                # Ejecutar la medición
                if measure_and_save_pod_metrics "$base_pod_name" "$pod_type" "$yaml_file" "$NAMESPACE"; then
                    log "DEBUG" "Job completado exitosamente: $base_pod_name" >&2
                else
                    log "ERROR" "Job falló: $base_pod_name" >&2
                fi
                
                # Liberar slot
                echo >&3
            ) &
            
            local pid=$!
            ALL_BACKGROUND_PIDS+=("$pid")
            total_jobs=$((total_jobs + 1))
            job_count=$((job_count + 1))
            
            log "DEBUG" "Lanzado job $job_count/$total_jobs (PID: $pid) para $base_pod_name" >&2
        done
    done

    # Esperar a que todos los jobs terminen
    log "INFO" "Esperando que terminen $total_jobs jobs..." >&2
    local failed_jobs=0
    
    for pid in "${ALL_BACKGROUND_PIDS[@]}"; do
        if wait "$pid"; then
            log "DEBUG" "Job $pid completado exitosamente" >&2
        else
            log "ERROR" "Job $pid falló" >&2
            ((failed_jobs++))
        fi
    done

    # Limpiar fifo
    exec 3>&-
    rm -f "$fifo_path"

    if [[ $failed_jobs -eq 0 ]]; then
        log "INFO" "Todos los pods procesados exitosamente" >&2
        return 0
    else
        log "ERROR" "$failed_jobs jobs fallaron" >&2
        return 1
    fi
}
# ========================================
# CONSOLIDACIÓN Y GENERACIÓN DE REPORTES
# ========================================

summarize_results() {
    log "INFO" "Generando resumen global de métricas..." >&2

    local temp_files_count=0
    for temp_file in "$TEMP_DIR"/*.json; do
        if [[ -f "$temp_file" ]]; then
            temp_files_count=$((temp_files_count + 1))
        fi
    done

    log "DEBUG" "Encontrados $temp_files_count archivos temporales para consolidar" >&2

    if [ "$temp_files_count" -eq 0 ]; then
        log "WARN" "No se encontraron archivos temporales para consolidar" >&2
        return 1
    fi

    # Consolidar todos los JSONs en uno
    jq -s '.' "${TEMP_DIR}"/*.json > "${RESULTS_JSON}.tmp"

    # Verificar que el archivo temporal se creó correctamente
    if [[ ! -f "${RESULTS_JSON}.tmp" ]]; then
        log "ERROR" "No se pudo crear el archivo temporal ${RESULTS_JSON}.tmp" >&2
        return 1
    fi

    # Crear JSON final con estructura completa y manejo seguro de valores
    jq -n \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg scheduler "$SCHED_IMPL" \
        --argjson pods_per_type "$NUM_PODS" \
        --argjson max_concurrent "$MAX_CONCURRENT_PODS" \
        --argjson pod_metrics "$(cat "${RESULTS_JSON}.tmp")" \
        '{
            test_timestamp: $timestamp,
            scheduler_implementation: $scheduler,
            pods_per_type: $pods_per_type,
            max_concurrent_pods: $max_concurrent,
            pod_metrics: $pod_metrics,
            aggregate_metrics: (
                $pod_metrics |
                {
                    total_pods: length,
                    
                    # Filtramos solo valores numéricos para cada métrica
                    avg_scheduling_latency: (
                        map(select(.scheduling_latency_seconds | type == "number")) | 
                        map(.scheduling_latency_seconds) | 
                        if length > 0 then add / length else 0 end
                    ),
                    
                    avg_pending_running_latency: (
                        map(select(.latency_pending_running_seconds | type == "number")) | 
                        map(.latency_pending_running_seconds) | 
                        if length > 0 then add / length else 0 end
                    ),
                    
                    avg_pull_start_latency: (
                        map(select(.pull_start_latency_seconds | type == "number")) | 
                        map(.pull_start_latency_seconds) | 
                        if length > 0 then add / length else 0 end
                    ),
                    
                    avg_scheduler_cpu: (
                        map(select(.scheduler_cpu_millicores | type == "number")) | 
                        map(.scheduler_cpu_millicores) | 
                        if length > 0 then add / length else 0 end
                    ),
                    
                    avg_scheduler_memory: (
                        map(select(.scheduler_memory_mib | type == "number")) | 
                        map(.scheduler_memory_mib) | 
                        if length > 0 then add / length else 0 end
                    ),
                    
                    # Para las sumas, solo sumamos valores numéricos válidos
                    total_list_ops: (
                        map(select(.list_ops | type == "number")) | 
                        map(.list_ops) | 
                        add // 0
                    ),
                    
                    total_retries: (
                        map(select(.retries | type == "number")) | 
                        map(.retries) | 
                        add // 0
                    ),
                    
                    total_implicit_retries: (
                        map(select(.implicit_retries | type == "number")) | 
                        map(.implicit_retries) | 
                        add // 0
                    ),
                    
                    total_events: (
                        map(select(.events | type == "number")) | 
                        map(.events) | 
                        add // 0
                    )
                }
            )
        }' > "$RESULTS_JSON"

    # Verificar que el JSON final se creó correctamente
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Error al generar el JSON final $RESULTS_JSON" >&2
        rm -f "${RESULTS_JSON}.tmp"
        return 1
    fi

    # Verificar que el archivo final no está vacío
    if [[ ! -s "$RESULTS_JSON" ]]; then
        log "ERROR" "El archivo JSON final está vacío: $RESULTS_JSON" >&2
        rm -f "${RESULTS_JSON}.tmp"
        return 1
    fi

    # Limpiar temporal
    rm -f "${RESULTS_JSON}.tmp"

    # Validar que el JSON generado es válido
    if jq empty "$RESULTS_JSON" 2>/dev/null; then
        log "INFO" "Archivo combinado generado exitosamente: ${RESULTS_JSON}" >&2
        
        # Mostrar estadísticas básicas del archivo generado
        local total_pods
        total_pods=$(jq '.aggregate_metrics.total_pods' "$RESULTS_JSON")
        log "DEBUG" "Total de pods procesados en el resumen: $total_pods" >&2
        
        return 0
    else
        log "ERROR" "El archivo JSON generado no es válido: $RESULTS_JSON" >&2
        return 1
    fi
}

# ========================================
# LIMPIEZA COMPLETA
# ========================================

cleanup() {
    log "DEBUG" "Ejecutando limpieza completa de recursos"

    # 1. Limpiar pods activos
    cleanup_active_pods

    # 2. Limpiar directorio temporal (excepto si estamos en medio de una ejecución)
    if [[ -d "$TEMP_DIR" && "${PRESERVE_TEMP:-false}" != "true" ]]; then
        safe_run rm -rf "$TEMP_DIR"
        log "DEBUG" "Directorio temporal eliminado: $TEMP_DIR"
    fi

    # 3. Limpieza adicional de Kubernetes
    log "DEBUG" "Limpieza final de recursos de Kubernetes"
    safe_run kubectl delete --all pods --namespace "$NAMESPACE" --ignore-not-found=true --wait=false
}

# ========================================
# EJECUCIÓN PRINCIPAL
# ========================================

main() {
    log "INFO" "=== INICIO DE TESTS DE SCHEDULER ===" >&2
    log "INFO" "Scheduler: $SCHED_IMPL, Pods por tipo: $NUM_PODS, Máximo concurrente: $MAX_CONCURRENT_PODS" >&2

    trap cleanup EXIT
    initialize_test
    clean_namespace

    # Ejecutar tests
    if run_all_tests_parallel; then
        log "SUCCESS" "Tests completados exitosamente" >&2
    else
        log "ERROR" "Algunos tests fallaron" >&2
    fi

    # Consolidar resultados
    if summarize_results; then
        generate_metrics_files
        log "SUCCESS" "=== TESTS COMPLETADOS ===" >&2

        log "SUCCESS" "=== TESTS COMPLETADOS EXITOSAMENTE ==="
        log "INFO" "Métricas consolidadas: $RESULTS_JSON"
        log "INFO" "Todos los archivos guardados en: $BASE_DIR"
        log "INFO" "Estructura de directorios:"
        log "INFO" "  📁 $BASE_DIR/"
        log "INFO" "  └── 📁 metrics/"
        log "INFO" "      ├── 📄 scheduler_metrics_${TIMESTAMP}.json"
        log "INFO" "      ├── 📄 scheduling_metrics_${TIMESTAMP}.json"
        log "INFO" "      ├── 📄 cluster_pod_metrics_${TIMESTAMP}.json"
        log "INFO" "      ├── 📄 scheduler_comparison_${TIMESTAMP}.json"
        log "INFO" "      └── 📄 test_summary_${TIMESTAMP}.txt"
    else
        log "ERROR" "Error en la consolidación de métricas" >&2
        return 1
    fi
}

# Ejecutar función principal
main "$@"
