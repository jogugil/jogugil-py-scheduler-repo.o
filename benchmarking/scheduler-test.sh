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

# Estructura de directorios organizada por scheduler
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
    #measure_and_save_pod_metrics "$base_pod_name" "$pod_type" "$yaml_file" "$NAMESPACE"
    local base_pod_name=$1 pod_type=$2 yaml_file=$3 namespace=$4

    log "DEBUG" "En measure_and_save_pod_metrics: base_pod_name='$base_pod_name', pod_type='$pod_type'"
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
    else
        log "WARN" "Pod $pod_name no existe, omitiendo métricas detalladas"
        # Registrar métricas básicas
        write_pod_metrics_to_temp "$pod_name" "$pod_type" "$latency" "N/A" "N/A" "0" "0" "0" "0" "0" "0"
    fi

    # Limpiar el pod después de medir
    log "DEBUG" "Eliminando pod $pod_name después de la medición"
    safe_run kubectl delete pod "$pod_name" -n "$namespace" --ignore-not-found=true --wait=false

    # Eliminar del registro
    unset CURRENT_PODS["$pod_name"]

    log "INFO" "Medición completada para pod: $pod_name"
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


run_all_tests_parallel() {
    log "INFO" "Ejecución paralela iniciada (máximo $MAX_CONCURRENT_PODS pods)"
    local total_jobs=0
  
    for pod_type in "${POD_TYPES[@]}"; do
	base_pod_name="${pod_type}-pod-"
        for i in $(seq 1 "$NUM_PODS"); do
            (
                base_pod_name="${base_pod_name}${i}"
                yaml_file="./${pod_type}/${pod_type}-pod.yaml"

                # Verificar que el YAML existe
                if [[ ! -f "$yaml_file" ]]; then
                    log "ERROR" "Archivo YAML no encontrado: $yaml_file"
                    exit 1
                fi

                log "DEBUG" "Iniciando trabajo para pod: $base_pod_name"
                measure_and_save_pod_metrics "$base_pod_name" "$pod_type" "$yaml_file" "$NAMESPACE"

            ) &

            # ✅ GUARDAR el PID REALMENTE
            local pid=$!
            ALL_BACKGROUND_PIDS+=($pid)
            log "DEBUG" "Lanzado job para $base_pod_name (PID: $pid)"
            total_jobs=$((total_jobs + 1))

            # Control de concurrencia
            while [ "$(jobs -rp | wc -l)" -ge "$MAX_CONCURRENT_PODS" ]; do
                sleep 2
            done
        done
    done

    # ✅ ESPERAR con gestión de errores
    log "INFO" "Esperando que terminen $total_jobs jobs..."
    local failed_jobs=0
    for pid in "${ALL_BACKGROUND_PIDS[@]}"; do
        if wait "$pid"; then
            log "DEBUG" "Job $pid completado exitosamente"
        else
            log "ERROR" "Job $pid falló con código: $?"
            ((failed_jobs++))
        fi
    done

    if [ $failed_jobs -eq 0 ]; then
        log "INFO" "Todos los pods procesados exitosamente"
    else
        log "ERROR" "$failed_jobs jobs fallaron"
        return 1
    fi
}

# ========================================
# CONSOLIDACIÓN Y GENERACIÓN DE REPORTES
# ========================================

summarize_results() {
    log "INFO" "Generando resumen global de métricas..."
    
    local temp_files_count=0
    for temp_file in "$TEMP_DIR"/*.json; do
        if [[ -f "$temp_file" ]]; then
            temp_files_count=$((temp_files_count + 1))
        fi
    done

    log "DEBUG" "Encontrados $temp_files_count archivos temporales para consolidar"

    if [ "$temp_files_count" -eq 0 ]; then
        log "WARN" "No se encontraron archivos temporales para consolidar"
        return 1
    fi

    # Consolidar todos los JSONs en uno
    jq -s '.' "${TEMP_DIR}"/*.json > "${RESULTS_JSON}.tmp"
    
    # Crear JSON final con estructura completa
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
                    avg_scheduling_latency: (map(.scheduling_latency_seconds) | add / length),
                    avg_pending_running_latency: (map(.latency_pending_running_seconds) | add / length),
                    avg_pull_start_latency: (map(.pull_start_latency_seconds) | add / length),
                    avg_scheduler_cpu: (map(.scheduler_cpu_millicores) | add / length),
                    avg_scheduler_memory: (map(.scheduler_memory_mib) | add / length),
                    total_list_ops: (map(.list_ops) | add),
                    total_retries: (map(.retries) | add),
                    total_implicit_retries: (map(.implicit_retries) | add),
                    total_events: (map(.events) | add)
                }
            )
        }' > "$RESULTS_JSON"

    # Limpiar temporal
    rm -f "${RESULTS_JSON}.tmp"
    
    log "INFO" "Archivo combinado: ${RESULTS_JSON}"
}

generate_metrics_files() {
    log "INFO" "Generando archivos específicos de métricas..."
    
    if [[ ! -f "$RESULTS_JSON" ]]; then
        log "ERROR" "No se encuentra el JSON consolidado: $RESULTS_JSON"
        return 1
    fi
    
    # 1. Archivo de métricas de scheduling
    local metrics_file="${METRICS_DIR}/scheduling_metrics_${TIMESTAMP}.json"
    jq '{
        scheduler: .scheduler_implementation,
        timestamp: .test_timestamp,
        scheduling_metrics: .aggregate_metrics
    }' "$RESULTS_JSON" > "$metrics_file"
    log "INFO" "Métricas de scheduling guardadas en: $metrics_file"
    
    # 2. Archivo de información del cluster (métricas por pod)
    local cluster_info_file="${METRICS_DIR}/cluster_pod_metrics_${TIMESTAMP}.json"
    jq '{
        scheduler: .scheduler_implementation,
        timestamp: .test_timestamp,
        pod_metrics: .pod_metrics
    }' "$RESULTS_JSON" > "$cluster_info_file"
    log "INFO" "Información del cluster guardada en: $cluster_info_file"
    
    # 3. Archivo comparativo para diferentes schedulers
    local comparison_file="${METRICS_DIR}/scheduler_comparison_${TIMESTAMP}.json"
    jq '{
        scheduler_type: .scheduler_implementation,
        test_configuration: {
            pods_per_type: .pods_per_type,
            max_concurrent: .max_concurrent_pods,
            total_pods: .aggregate_metrics.total_pods
        },
        performance_metrics: {
            avg_scheduling_latency: .aggregate_metrics.avg_scheduling_latency,
            avg_pending_running_latency: .aggregate_metrics.avg_pending_running_latency,
            avg_pull_start_latency: .aggregate_metrics.avg_pull_start_latency,
            scheduler_resource_usage: {
                cpu: .aggregate_metrics.avg_scheduler_cpu,
                memory: .aggregate_metrics.avg_scheduler_memory
            },
            efficiency_metrics: {
                list_ops: .aggregate_metrics.total_list_ops,
                retries: .aggregate_metrics.total_retries,
                implicit_retries: .aggregate_metrics.total_implicit_retries,
                events: .aggregate_metrics.total_events
            }
        }
    }' "$RESULTS_JSON" > "$comparison_file"
    log "INFO" "Datos comparativos guardados en: $comparison_file"
    
    # 4. Resumen en texto plano
    local summary_file="${METRICS_DIR}/test_summary_${TIMESTAMP}.txt"
    {
        echo "=== RESUMEN DE PRUEBAS DE SCHEDULER ==="
        echo "Scheduler: $SCHED_IMPL"
        echo "Fecha: $(date)"
        echo "Pods por tipo: $NUM_PODS"
        echo "Máximo concurrente: $MAX_CONCURRENT_PODS"
        echo "Directorio de resultados: $BASE_DIR"
        echo ""
        echo "=== MÉTRICAS AGREGADAS ==="
        jq -r '"Total pods: \(.aggregate_metrics.total_pods)
Latencia promedio scheduling: \(.aggregate_metrics.avg_scheduling_latency) segundos
Latencia promedio pending-running: \(.aggregate_metrics.avg_pending_running_latency) segundos  
Latencia promedio pull-start: \(.aggregate_metrics.avg_pull_start_latency) segundos
CPU promedio scheduler: \(.aggregate_metrics.avg_scheduler_cpu) millicores
MEM promedio scheduler: \(.aggregate_metrics.avg_scheduler_memory) MiB
Total list operations: \(.aggregate_metrics.total_list_ops)
Total retries: \(.aggregate_metrics.total_retries)
Total implicit retries: \(.aggregate_metrics.total_implicit_retries)
Total events: \(.aggregate_metrics.total_events)"' "$RESULTS_JSON"
    } > "$summary_file"
    log "INFO" "Resumen guardado en: $summary_file"
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
    log "INFO" "=== INICIO DE TESTS DE SCHEDULER ==="
    log "INFO" "Scheduler: $SCHED_IMPL, Pods por tipo: $NUM_PODS, Máximo concurrente: $MAX_CONCURRENT_PODS"

    # Configurar trap para limpieza
    trap cleanup EXIT

    # Inicializar test
    initialize_test

    # Limpiar namespace antes de empezar
    clean_namespace
    register_operation "start_tests" "scheduler-benchmark"

    # Ejecutar tests en paralelo
    run_all_tests_parallel

    audit_cluster_health "post_tests"
    
    # Consolidar métricas y generar reportes
    if summarize_results; then
        generate_metrics_files
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
        log "ERROR" "Error en la consolidación de métricas"
        return 1
    fi
}

# Ejecutar función principal
main "$@"
