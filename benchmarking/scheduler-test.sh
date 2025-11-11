#!/bin/bash

# ========================================
# CARGAR LOGGING Y MANEJO DE ERRORES
# ========================================
source ./logger.sh
enable_error_trapping

# ========================================
# CONFIGURACIÓN GLOBAL
# ========================================
SCHED_IMPL=${1:-polling}
NUM_PODS=${2:-20}
MAX_CONCURRENT_PODS=${3:-5}  # Límite de pods concurrentes
NAMESPACE="test-scheduler"
SCHEDULER_NAME="my-scheduler"
RESULTS_DIR="./${SCHED_IMPL}/metrics"
TEMP_DIR="/tmp/pod_metrics_$$"
RESULTS_JSON="${RESULTS_DIR}/scheduler_metrics_$(date +%Y%m%d_%H%M%S).json"
METRICS_DIR="./${SCHEDULER_NAME}/metrics"
POD_TYPES=("cpu-heavy" "ram-heavy" "nginx" "test-basic")

# Variables para control de ejecución
declare -a CURRENT_PODS=()

# ========================================
# FUNCIÓN SAFE_RUN
# ========================================
safe_run() {
    "$@" || log "WARN" "Comando '$*' falló pero se ignora"
}

# ========================================
# FUNCIONES DE CONTROL DE EJECUCIÓN
# ========================================

# Registrar un pod activo
register_pod() {
    local pod_name=$1
    CURRENT_PODS+=("$pod_name")
    log "DEBUG" "Pod registrado: $pod_name (total: ${#CURRENT_PODS[@]})"
}

# Limpiar todos los pods activos
cleanup_active_pods() {
    if [ ${#CURRENT_PODS[@]} -gt 0 ]; then
        log "INFO" "Limpiando ${#CURRENT_PODS[@]} pods activos..."
        for pod in "${CURRENT_PODS[@]}"; do
            log "DEBUG" "Eliminando pod: $pod"
            safe_run kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found=true --force --grace-period=0
        done
        CURRENT_PODS=()
    fi
}

# ========================================
# CONTROL DE CONCURRENCIA CON SEMÁFOROS
# ========================================

# Semáforo simple usando FIFO
init_semaphore() {
    local max_jobs=$1
    mkfifo /tmp/scheduler_semaphore.$$
    for ((i=0; i<max_jobs; i++)); do
        echo > /tmp/scheduler_semaphore.$$
    done
}

acquire_semaphore() {
    read -u 9
}

release_semaphore() {
    echo > /tmp/scheduler_semaphore.$$
}

cleanup_semaphore() {
    rm -f /tmp/scheduler_semaphore.$$
}

# ========================================
# INICIALIZACIÓN
# ========================================
initialize_test() {
    log "INFO" "Inicializando test de scheduler: $SCHED_IMPL"
    log "INFO" "Número de pods por tipo: $NUM_PODS"
    log "INFO" "Máximo pods concurrentes: $MAX_CONCURRENT_PODS"
    log "INFO" "Namespace: $NAMESPACE"

    mkdir -p "$METRICS_DIR" "$RESULTS_DIR" "$TEMP_DIR"
    log "DEBUG" "Directorios creados: $METRICS_DIR, $RESULTS_DIR, $TEMP_DIR"

    RESULTS_FILE="$METRICS_DIR/results.csv"
    echo "timestamp,pod_name,latency,latency_pending_running,pull_start_latency,cpu_usage,mem_usage,list_ops,retries,implicit_retries,events" > "$RESULTS_FILE"
    log "DEBUG" "Archivo de resultados CSV inicializado: $RESULTS_FILE"
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

    local latency=$(safe_run kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" \
        --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{"\n"}{end}' \
        | grep -E 'Pulling|Started' \
        | awk '/Pulling/ {pull=$1} /Started/ {start=$1; print (mktime(gensub(/[-:T]/," ","g",start)) - mktime(gensub(/[-:T]/," ","g",pull)))}')

    if [[ -z "$latency" ]]; then
        log "DEBUG" "No se pudo calcular pull_start_latency para $pod_name"
        echo "N/A"
    else
        log "DEBUG" "Pull_start_latency para $pod_name: $latency segundos"
        echo "$latency"
    fi
}

get_pending_running_latency() {
    local pod_name=$1
    local namespace=$2
    log "DEBUG" "Calculando pending_running_latency para pod: $pod_name"

    local creation_time=$(safe_run kubectl -n $namespace get pod $pod_name -o jsonpath='{.metadata.creationTimestamp}')
    local start_time=$(safe_run kubectl -n $namespace get pod $pod_name -o jsonpath='{.status.startTime}')

    if [[ -n "$creation_time" && -n "$start_time" ]]; then
        local creation_sec=$(date -d "$creation_time" +%s)
        local start_sec=$(date -d "$start_time" +%s)
        local latency=$((start_sec - creation_sec))
        log "DEBUG" "Pending_running_latency para $pod_name: $latency segundos"
        echo $latency
    else
        log "WARN" "No se pudieron obtener tiempos para calcular pending_running_latency de $pod_name"
        echo "N/A"
    fi
}

get_scheduler_resources_avg() {
    log "DEBUG" "Calculando uso promedio de recursos del scheduler"
    local cpu_sum=0 mem_sum=0 samples=0
    local scheduler_pod=$(safe_run kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name | head -1 | sed 's#pod/##')

    if [[ -z "$scheduler_pod" ]]; then
        log "WARN" "No se encontró el pod del scheduler"
        echo "0m 0Mi"
        return
    fi

    for i in {1..3}; do
        local top_output=$(safe_run kubectl top pod "$scheduler_pod" -n kube-system || echo "")
        if [[ $(echo "$top_output" | wc -l) -gt 1 ]]; then
            local cpu=$(echo "$top_output" | awk 'NR>1 {print $2}' | sed 's/m//')
            local mem=$(echo "$top_output" | awk 'NR>1 {print $3}' | sed 's/Mi//')
            if [[ "$cpu" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]]; then
                cpu_sum=$((cpu_sum + cpu))
                mem_sum=$((mem_sum + mem))
                samples=$((samples + 1))
                log "DEBUG" "Muestra $i: CPU=${cpu}m, MEM=${mem}Mi"
            fi
        fi
        sleep 1
    done

    if [[ $samples -gt 0 ]]; then
        local avg_cpu=$((cpu_sum/samples))
        local avg_mem=$((mem_sum/samples))
        log "DEBUG" "Uso promedio del scheduler: CPU=${avg_cpu}m, MEM=${avg_mem}Mi"
        echo "${avg_cpu}m ${avg_mem}Mi"
    else
        log "WARN" "No se pudieron obtener métricas del scheduler"
        echo "0m 0Mi"
    fi
}

get_list_ops() {
    local pod_name=$1
    log "DEBUG" "Calculando list_ops para pod: $pod_name"

    local scheduler_pod=$(safe_run kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name | head -1 | sed 's#pod/##')
    local list_ops=0

    if [[ -n "$scheduler_pod" ]]; then
        local list_before=$(safe_run kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep -c $pod_name || echo "0")
        sleep 2
        local list_after=$(safe_run kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep -c $pod_name || echo "0")
        list_ops=$((list_after - list_before))
        if [[ $list_ops -lt 0 ]]; then
            list_ops=0
        fi
        log "DEBUG" "List_ops para $pod_name: $list_ops"
    else
        log "WARN" "No se pudo calcular list_ops - scheduler pod no encontrado"
    fi

    echo "$list_ops"
}

get_scheduler_attempts_events() {
    local pod_name=$1
    log "DEBUG" "Calculando attempts y eventos para pod: $pod_name"

    local scheduler_pod=$(safe_run kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name | head -1 | sed 's#pod/##')
    local retries=0 implicit_retries=0 events=0

    if [[ -n "$scheduler_pod" ]]; then
        local total_attempts=$(safe_run kubectl -n kube-system logs "$scheduler_pod" --since=1h | grep -c "Attempting to schedule pod: $NAMESPACE/$pod_name" || echo "0")
        local successful=$(safe_run kubectl -n kube-system logs "$scheduler_pod" --since=1h | grep -c "Bound $NAMESPACE/$pod_name" || echo "0")

        total_attempts=$(clean_numeric_value "$total_attempts")
        successful=$(clean_numeric_value "$successful")
        implicit_retries=$((total_attempts - successful))
        retries=$(safe_run kubectl -n kube-system logs "$scheduler_pod" | grep -c "$pod_name" | grep -c -E "retry|Retry|error|Error" || echo "0")
        events=$(safe_run kubectl -n kube-system logs "$scheduler_pod" | grep -c -E "Bound.*$pod_name|Scheduled.*$pod_name" || echo "0")

        log "DEBUG" "Métricas de scheduler para $pod_name: retries=$retries, implicit_retries=$implicit_retries, events=$events"
    else
        log "WARN" "No se pudieron obtener attempts/events - scheduler pod no encontrado"
    fi

    echo "$retries $implicit_retries $events"
}

# Función mejorada para métricas del scheduler
get_scheduler_detailed_metrics() {
    local scheduler_pod=$(safe_run kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name | head -1 | sed 's#pod/##')

    if [[ -z "$scheduler_pod" ]]; then
        log "WARN" "No se encontró el pod del scheduler"
        echo "0 0 0 0 false"
        return
    fi

    local pod_info=$(kubectl -n kube-system get pod "$scheduler_pod" -o json 2>/dev/null || echo "")

    if [[ -n "$pod_info" ]]; then
        local cpu=$(echo "$pod_info" | jq -r '.spec.containers[0].resources.requests.cpu // "0m"' | sed 's/m//')
        local mem=$(echo "$pod_info" | jq -r '.spec.containers[0].resources.requests.memory // "0Mi"' | sed 's/Mi//')
        local restarts=$(echo "$pod_info" | jq -r '.status.containerStatuses[0].restartCount // 0')
        local ready=$(echo "$pod_info" | jq -r '.status.containerStatuses[0].ready // "false"')
        local creation_timestamp=$(echo "$pod_info" | jq -r '.metadata.creationTimestamp')
        local age=$(date -d "$creation_timestamp" +%s 2>/dev/null || echo "0")
        local now=$(date +%s)
        local pod_age=$((now - age))

        echo "$cpu $mem $restarts $pod_age $ready"
    else
        echo "0 0 0 0 false"
    fi
}

record_metrics() {
    local pod_name=$1 latency=$2 latency_pending_running=$3 pull_start_latency=$4 cpu=$5 mem=$6 \
          list_ops=$7 retries=$8 implicit_retries=$9 events=${10}

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$timestamp,$pod_name,$latency,$latency_pending_running,$pull_start_latency,$cpu,$mem,$list_ops,$retries,$implicit_retries,$events" >> "$RESULTS_FILE"

    log "DEBUG" "Métricas registradas en CSV para $pod_name: latency=${latency}s, cpu=${cpu}, mem=${mem}"
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

measure_and_save_pod_metrics() {
    local base_pod_name=$1 pod_type=$2 yaml_file=$3 namespace=$4

    log "INFO" "Iniciando medición de pod: tipo=$pod_type, yaml=$yaml_file"

    # Limpiar pods anteriores por label
    log "DEBUG" "Eliminando pods existentes con label app=$pod_type"
    safe_run kubectl delete pod -l app=$pod_type -n "$namespace" --ignore-not-found=true --wait=false
    sleep 1

    local t0=$(date +%s)
    log "DEBUG" "Tiempo de inicio de medición: $t0"

    # Crear el pod
    log "INFO" "Creando pod desde YAML: $yaml_file"
    local created_pod
    created_pod=$(kubectl create -f "$yaml_file" -n "$namespace" -o jsonpath='{.metadata.name}' 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Error al crear pod desde $yaml_file: $created_pod"
        return 1
    fi

    log "INFO" "Pod creado exitosamente: $created_pod"
    local pod_name="$created_pod"

    # Registrar el pod para limpieza
    register_pod "$pod_name"

    # Esperar a que el pod esté listo
    log "INFO" "Esperando a que el pod $pod_name esté Ready"

    if wait_for_pod_ready "$pod_name" "$namespace"; then
        log "INFO" "Pod $pod_name está Ready y operativo"
    else
        log "WARN" "Pod $pod_name no alcanzó estado Ready dentro del timeout"
        # Continuamos para obtener métricas parciales
    fi

    sleep 2

    # Calcular métricas
    local latency=$(( $(date +%s) - t0 ))
    log "INFO" "Latencia total de scheduling: ${latency} segundos"

    # Solo calcular métricas si el pod existe
    local pod_exists=$(kubectl get pod "$pod_name" -n "$namespace" --ignore-not-found=true | wc -l)
    if [ "$pod_exists" -gt 1 ]; then
        log "DEBUG" "Calculando métricas detalladas para $pod_name"
        local pending_latency=$(get_pending_running_latency "$pod_name" "$namespace")
        local pull_latency=$(get_pull_start_latency "$pod_name" "$namespace")
        read -r cpu mem <<< "$(get_scheduler_resources_avg)"
        local list_ops=$(get_list_ops "$pod_name")
        read -r retries implicit_retries events <<< "$(get_scheduler_attempts_events "$pod_name")"

        # Registrar métricas
        log "DEBUG" "Registrando métricas para $pod_name"
        write_pod_metrics_to_temp "$pod_name" "$pod_type" "$latency" "$pending_latency" "$pull_latency" "$cpu" "$mem" "$list_ops" "$retries" "$implicit_retries" "$events"
        record_metrics "$pod_name" "$latency" "$pending_latency" "$pull_latency" "$cpu" "$mem" "$list_ops" "$retries" "$implicit_retries" "$events"
    else
        log "WARN" "Pod $pod_name no existe, omitiendo métricas detalladas"
        # Registrar métricas básicas
        write_pod_metrics_to_temp "$pod_name" "$pod_type" "$latency" "N/A" "N/A" "0" "0" "0" "0" "0" "0"
        record_metrics "$pod_name" "$latency" "N/A" "N/A" "0" "0" "0" "0" "0" "0"
    fi

    # Limpiar el pod después de medir
    log "DEBUG" "Eliminando pod $pod_name después de la medición"
    safe_run kubectl delete pod "$pod_name" -n "$namespace" --ignore-not-found=true --wait=false

    log "INFO" "Medición completada para pod: $pod_name"
    return 0
}

# ========================================
# EJECUCIÓN PARALELA CONTROLADA
# ========================================

run_all_tests_parallel() {
    log "INFO" "Iniciando ejecución paralela CONTROLADA"
    log "INFO" "Total de pods a crear: $((${#POD_TYPES[@]} * NUM_PODS))"
    log "INFO" "Máximo concurrente: $MAX_CONCURRENT_PODS"

    # Inicializar semáforo
    init_semaphore $MAX_CONCURRENT_PODS
    exec 9<> /tmp/scheduler_semaphore.$$

    declare -a pids=()
    local total_pods=0
    local completed_pods=0

    for pod_type in "${POD_TYPES[@]}"; do
        log "INFO" "Procesando tipo de pod: $pod_type"
        for i in $(seq 1 "$NUM_PODS"); do
            local base_pod_name="${pod_type}-pod-${i}"
            local yaml_file="./${pod_type}/${pod_type}-pod.yaml"

            if [[ ! -f "$yaml_file" ]]; then
                log "ERROR" "Archivo YAML no encontrado: $yaml_file"
                continue
            fi

            # Adquirir semáforo (control de concurrencia)
            acquire_semaphore

            log "DEBUG" "Programando pod: $base_pod_name"
            (
                # Esta sub-shell se ejecuta con el semáforo adquirido
                measure_and_save_pod_metrics "$base_pod_name" "$pod_type" "$yaml_file" "$NAMESPACE"
                release_semaphore
            ) &
            
            local pid=$!
            pids+=($pid)
            register_background_pid $pid
            total_pods=$((total_pods + 1))

            log "DEBUG" "Pod $base_pod_name lanzado (PID: $pid) - Total activos: ${#pids[@]}"
            
            # Pequeña pausa para evitar saturación
            sleep 1
        done
    done

    log "INFO" "Esperando a que completen $total_pods procesos..."
    
    # Esperar a todos los procesos
    for pid in "${pids[@]}"; do
        if wait "$pid" 2>/dev/null; then
            completed_pods=$((completed_pods + 1))
            log "DEBUG" "Proceso $pid completado ($completed_pods/$total_pods)"
        else
            local wait_status=$?
            completed_pods=$((completed_pods + 1))
            log "WARN" "Proceso $pid terminó con error ($completed_pods/$total_pods, status: $wait_status)"
        fi
    done

    # Limpiar semáforo
    exec 9>&-
    cleanup_semaphore

    log "INFO" "Ejecución paralela completada: $completed_pods/$total_pods pods procesados"
}

# ========================================
# CONSOLIDACIÓN Y JSON
# ========================================

consolidate_metrics_with_jq() {
    log "INFO" "Iniciando consolidación de métricas en JSON"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local json_array="[]"
    local temp_files_count=0

    for temp_file in "$TEMP_DIR"/*.json; do
        if [[ -f "$temp_file" ]]; then
            json_array=$(echo "$json_array" | safe_run jq ". + [$(cat "$temp_file")]")
            temp_files_count=$((temp_files_count + 1))
        fi
    done

    log "DEBUG" "Procesados $temp_files_count archivos temporales"

    safe_run jq -n \
        --arg timestamp "$timestamp" \
        --arg scheduler "$SCHED_IMPL" \
        --argjson pods_per_type "$NUM_PODS" \
        --argjson max_concurrent "$MAX_CONCURRENT_PODS" \
        --argjson pod_metrics "$json_array" \
        '{
            test_timestamp: $timestamp,
            scheduler_implementation: $scheduler,
            pods_per_type: $pods_per_type,
            max_concurrent_pods: $max_concurrent,
            pod_metrics: $pod_metrics,
            aggregate_metrics: {}
        }' > "$RESULTS_JSON"

    if [[ $? -eq 0 ]]; then
        log "INFO" "JSON final generado exitosamente: $RESULTS_JSON"
        log "DEBUG" "Tamaño del JSON: $(wc -c < "$RESULTS_JSON") bytes, $temp_files_count pods registrados"
    else
        log "ERROR" "Error al generar JSON final"
        return 1
    fi
}

# ========================================
# CÁLCULO DE MEDIAS
# ========================================

calculate_metrics_means() {
    log "INFO" "Calculando promedios de métricas desde CSV"

    if [[ ! -f "$RESULTS_FILE" ]]; then
        log "ERROR" "Archivo de resultados CSV no encontrado: $RESULTS_FILE"
        return 1
    fi

    local total_lines=$(wc -l < "$RESULTS_FILE" | tr -d ' ')
    if [[ $total_lines -le 1 ]]; then
        log "WARN" "No hay suficientes datos en el CSV para calcular promedios (solo $total_lines líneas)"
        return 0
    fi

    log "INFO" "Procesando $((total_lines - 1)) registros de métricas"

    awk -F, '
    NR>1 {
        count++;
        sum_latency+=$3;
        sum_pending+=$4;
        sum_pull+=$5;
        sum_cpu+=$6;
        sum_mem+=$7;
        sum_list+=$8;
        sum_retries+=$9;
        sum_implicit+=$10;
        sum_events+=$11
    }
    END {
        if(count>0){
            print "=== RESUMEN DE MÉTRICAS ==="
            print "Total de pods procesados: " count
            print "Promedio Latencia: " sum_latency/count " segundos"
            print "Promedio Pending->Running: " sum_pending/count " segundos"
            print "Promedio Pull->Start: " sum_pull/count " segundos"
            print "Promedio CPU: " sum_cpu/count " millicores"
            print "Promedio MEM: " sum_mem/count " MiB"
            print "Promedio List Ops: " sum_list/count
            print "Promedio Retries: " sum_retries/count
            print "Promedio Implicit Retries: " sum_implicit/count
            print "Promedio Eventos: " sum_events/count
        } else {
            print "No hay métricas para calcular promedio"
        }
    }' "$RESULTS_FILE"
}

# ========================================
# LIMPIEZA COMPLETA
# ========================================

cleanup() {
    log "DEBUG" "Ejecutando limpieza completa de recursos"

    # 1. Limpiar pods activos
    cleanup_active_pods

    # 2. Limpiar directorio temporal
    if [[ -d "$TEMP_DIR" ]]; then
        safe_run rm -rf "$TEMP_DIR"
        log "DEBUG" "Directorio temporal eliminado: $TEMP_DIR"
    fi

    # 3. Limpieza adicional de Kubernetes
    log "DEBUG" "Limpieza final de recursos de Kubernetes"
    safe_run kubectl delete --all pods --namespace "$NAMESPACE" --ignore-not-found=true
}

# ========================================
# EJECUCIÓN PRINCIPAL
# ========================================

main() {
    log "INFO" "=== INICIO DE TESTS DE SCHEDULER ==="
    log "INFO" "Scheduler: $SCHED_IMPL, Pods por tipo: $NUM_PODS, Máximo concurrente: $MAX_CONCURRENT_PODS"

    # Configurar trap para limpieza
    trap cleanup EXIT

    # Inicializar test
    initialize_test

    # Ejecutar tests en paralelo
    run_all_tests_parallel

    # Calcular y mostrar promedios
    calculate_metrics_means

    # Consolidar métricas en JSON
    consolidate_metrics_with_jq

    log "INFO" "=== TESTS DE SCHEDULER COMPLETADOS EXITOSAMENTE ==="
    log "INFO" "Resultados: $RESULTS_FILE"
    log "INFO" "Métricas consolidadas: $RESULTS_JSON"
}

# Ejecutar función principal
main "$@"
