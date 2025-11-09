#!/bin/bash
set -e

CLUSTER_NAME="sched-lab"
NAMESPACE="test-scheduler"
SCHED_IMAGE="my-py-scheduler:latest"
NGINX_IMAGE="nginx:latest"
SCHEDULER_NAME="my-scheduler"
POD_NAME="test-pod"
RESULTS_FILE="scheduler_metrics_$(date +%Y%m%d_%H%M%S).csv"

# Variables globales para métricas
declare -A METRICS_TEST_POD
declare -A METRICS_NGINX_POD

# Inicializar arrays
METRICS_TEST_POD=(
    ["latency"]="N/A"
    ["latency_pending_running"]="N/A"
    ["list_ops"]="N/A"
    ["cpu"]="N/A"
    ["mem"]="N/A"
    ["pull_start_latency"]="N/A"
    ["retries"]="N/A"
)

METRICS_NGINX_POD=(
    ["latency"]="N/A"
    ["latency_pending_running"]="N/A"
    ["list_ops"]="N/A"
    ["cpu"]="N/A"
    ["mem"]="N/A"
    ["pull_start_latency"]="N/A"
    ["retries"]="N/A"
)

# Inicializar archivo de resultados
echo "timestamp,test_name,pod_name,scheduling_latency,processing_latency,total_latency,pending_running_latency,pull_start_latency,cpu_usage,mem_usage,list_ops,success_rate,composite_load,cluster_state" > $RESULTS_FILE

# Función para registrar métricas
record_metrics() {
    local test_name=$1
    local pod_name=$2
    local scheduling_latency=$3
    local processing_latency=$4
    local total_latency=$5
    local pending_running_latency=$6
    local pull_start_latency=$7
    local cpu_usage=$8
    local mem_usage=$9
    local list_ops=${10}
    local success_rate=${11}
    local composite_load=${12}
    local cluster_state=${13}

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$timestamp,$test_name,$pod_name,$scheduling_latency,$processing_latency,$total_latency,$pending_running_latency,$pull_start_latency,$cpu_usage,$mem_usage,$list_ops,$success_rate,$composite_load,$cluster_state" >> $RESULTS_FILE
}

# Función para calcular métricas compuestas
calculate_composite_metrics() {
    local latency=$1
    local cpu=$2
    local mem=$3
    local success_rate=${4:-95}


    # Si la latencia no es numérica, no podemos calcular
    if [[ ! "$latency" =~ ^[0-9]+$ ]]; then
        echo "N/A"
        return
    fi

    # Convertir CPU a valor numérico (eliminar 'm' de millicores)
    local cpu_numeric=$(echo $cpu | sed 's/m//')

    # Calcular score de carga (0-100)
    local cpu_score=$(echo "scale=2; $cpu_numeric / 10" | bc 2>/dev/null || echo "0")
    local latency_score=$(echo "scale=2; $latency * 3" | bc 2>/dev/null || echo "0")
    local success_score=$(echo "scale=2; 100 - $success_rate" | bc 2>/dev/null || echo "0")

    local composite_load=$(echo "scale=2; ($cpu_score * 0.4) + ($latency_score * 0.3) + ($success_score * 0.3)" | bc 2>/dev/null || echo "0")

    echo $composite_load
}

# Función para obtener estado del cluster
get_cluster_state() {
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
    echo "$ready_nodes/$total_nodes"
}

# Función para calcular el tiempo Pull->Start
get_pull_start_latency() {
    local pod_name=$1
    local namespace=$2

    # Obtener eventos Pulling y Started del pod
    local latency=$(kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" \
        --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{"\n"}{end}' 2>/dev/null \
        | grep -E 'Pulling|Started' \
        | awk '
            /Pulling/ {pull=$1}
            /Started/ {start=$1; print (mktime(gensub(/[-:T]/," ","g",start)) - mktime(gensub(/[-:T]/," ","g",pull)))}
        ')
    # Si no se pudo calcular, devolver N/A
    if [[ -z "$latency" ]]; then
        echo "N/A"
    else
        echo "$latency"
    fi
}

# Función para calcular latencias de eventos
get_pod_event_timeline() {
    local POD_NAME=$1
    local NAMESPACE=$2
    
    # Obtener todos los eventos del pod y parsear tiempos
    kubectl get events -n $NAMESPACE --field-selector involvedObject.name=$POD_NAME \
        --sort-by=.lastTimestamp -o json 2>/dev/null | \
    jq -r '.items[] | select(.reason | test("Scheduled|Pulling|Pulled|Created|Started")) | "\(.lastTimestamp) \(.reason)"' | \
    while read timestamp reason; do
        epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo "0")
        echo "$epoch $reason"
    done
}


# Función para obtener métricas de recursos promediadas
get_scheduler_resources_avg() {
    # Tomar múltiples muestras
    local cpu_sum=0
    local mem_sum=0
    local samples=0

    for i in {1..3}; do
        local top_output=$(kubectl top pod -n kube-system 2>/dev/null | grep $SCHEDULER_NAME || echo "")
        if [[ -n "$top_output" ]]; then
            local cpu=$(echo "$top_output" | awk '{print $2}' | sed 's/m//')
            local mem=$(echo "$top_output" | awk '{print $3}' | sed 's/Mi//')
            cpu_sum=$((cpu_sum + cpu))
            mem_sum=$((mem_sum + mem))
            samples=$((samples + 1))
        fi
        sleep 1
    done

    if [[ $samples -gt 0 ]]; then
        local avg_cpu=$((cpu_sum / samples))
        local avg_mem=$((mem_sum / samples))
        echo "${avg_cpu}m ${avg_mem}Mi"
    else
        echo "N/A N/A"
    fi
}
get_scheduler_resources_avg() {
    local cpu_sum=0
    local mem_sum=0
    local samples=0

    for i in {1..3}; do
        # Buscar el pod del scheduler específico
        local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')

        if [[ -n "$scheduler_pod" ]]; then
            local top_output=$(kubectl top pod "$scheduler_pod" -n kube-system 2>/dev/null || echo "")
            if [[ -n "$top_output" ]] && [[ $(echo "$top_output" | wc -l) -gt 1 ]]; then
                local cpu_line=$(echo "$top_output" | awk 'NR>1')
                local cpu=$(echo "$cpu_line" | awk '{print $2}' | sed 's/m//')
                local mem=$(echo "$cpu_line" | awk '{print $3}' | sed 's/Mi//')

                # Verificar que son números válidos
                if [[ "$cpu" =~ ^[0-9]+$ ]] && [[ "$mem" =~ ^[0-9]+$ ]]; then
                    cpu_sum=$((cpu_sum + cpu))
                    mem_sum=$((mem_sum + mem))
                    samples=$((samples + 1))
                fi
            fi
        fi
        sleep 1
    done

    if [[ $samples -gt 0 ]]; then
        local avg_cpu=$((cpu_sum / samples))
        local avg_mem=$((mem_sum / samples))
        echo "${avg_cpu}m ${avg_mem}Mi"
    else
        echo "0m 0Mi"  # Default en lugar de N/A
    fi
}
# Función para limpiar valores numéricos
clean_numeric_value() {
    local value="$1"
    
    # Si el valor es N/A o está vacío, devolver 0
    if [[ "$value" == "N/A" ]] || [[ -z "$value" ]]; then
        echo "0"
        return
    fi
    
    # Convertir a string y eliminar todos los caracteres no numéricos
    value=$(echo "$value" | tr -d '\n\r\t ' | sed 's/[^0-9.]//g')
    
    # Si después de limpiar está vacío, devolver 0
    if [[ -z "$value" ]]; then
        echo "0"
    else
        # Forzar a ser tratado como número
        echo "$((value + 0))"
    fi
}
# Función para test de latencia manual
run_improved_latency_test() {
    local pod_name=$1
    local yaml_file=$2
    local test_name=$3

    echo ""
    echo "=== TEST MÉTRICAS: $test_name ==="

    # Limpiar pod previo
    kubectl delete pod $pod_name -n $NAMESPACE --ignore-not-found=true
    sleep 3

    # Obtener el pod del scheduler
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')

    # TIMESTAMP INICIAL en formato ISO para --since-time
    local start_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "TIMESTAMP INICIAL: $start_timestamp"

    local list_before=0
    if [[ -n "$scheduler_pod" ]]; then
        echo "=== Contando operaciones LIST ANTES del scheduling ==="
        # Método 1: Buscar operaciones de listado en logs recientes
        list_before=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | \
           grep -c -E "list.*pods|List.*pods|get.*pods|Get.*pods|watching|Watching" 2>/dev/null || echo "0")

        # LIMPIAR el valor
        list_before=$(echo "$list_before" | tr -d '\n' | tr -d ' ' | tr -d '\r')
        [[ -z "$list_before" ]] && list_before=0

        # Método 2: Si es 0, contar líneas totales recientes como estimación
        if [[ "$list_before" -eq "0" ]]; then
            list_before=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | wc -l 2>/dev/null || echo "0")
            list_before=$(echo "$list_before" | tr -d '\n' | tr -d ' ' | tr -d '\r')
            [[ -z "$list_before" ]] && list_before=0
        fi
    fi
    echo "Operaciones LIST ANTES: $list_before"

    # Registrar tiempo inicial
    local t0_sec=$(date -u +%s)
    echo "T0 (apply): $(date -u +"%H:%M:%S") - $t0_sec"

    kubectl apply -f $yaml_file -n $NAMESPACE
    echo "Pod $pod_name aplicado"

    # Esperar a que el pod esté listo
    kubectl wait --for=condition=Ready pod/$pod_name -n $NAMESPACE --timeout=120s

    # Pequeña pausa para logs
    sleep 5

    # OBTENER LOGS SOLO DESDE EL INICIO DEL TEST
    local test_logs=""
    if [[ -n "$scheduler_pod" ]]; then
        test_logs=$(kubectl -n kube-system logs "$scheduler_pod" --since-time="$start_timestamp" 2>/dev/null || echo "")
        echo "Logs capturados durante test: $(echo "$test_logs" | wc -l) líneas"
    fi

    # 2. Latencia del scheduler - BUSCAR EN LOGS DEL TEST
    # Obtener timestamp del último binding
    local t1_ts=$(kubectl -n kube-system logs -l app=$SCHEDULER_NAME --timestamps 2>/dev/null | \
               grep "Bound $NAMESPACE/$pod_name" | tail -1 | awk '{print $1}')

    local scheduler_latency="N/A"
    if [[ -n "$t1_ts" ]]; then
        # Convertir el timestamp ISO 8601 directamente a epoch con nanosegundos
        local t1_epoch=$(date -u -d "$t1_ts" +%s.%N 2>/dev/null || echo "0")
        if [[ $(echo "$t1_epoch > 0" | bc -l) -eq 1 ]]; then
            # Calcular latencia como decimal
            scheduler_latency=$(echo "$t1_epoch - $t0_sec" | bc -l)
        fi
    fi
    echo "Latencia scheduler: $scheduler_latency segundos"    


    # 4. Latencia Pull->Start
    local pull_start_latency=$(get_pull_start_latency "$pod_name" "$NAMESPACE")
    echo "Latencia Pull→Start: $pull_start_latency"

    # 5. Métricas de recursos
    read -r avg_cpu avg_mem <<< "$(get_scheduler_resources_avg)"
    echo "CPU (avg): $avg_cpu - MEM (avg): $avg_mem"

  # 6. CONTAR OPERACIONES LIST DESPUÉS del scheduling y CALCULAR DIFERENCIA
    local list_after=0
    local list_ops=0

    if [[ -n "$scheduler_pod" ]]; then
        echo "=== Contando operaciones LIST DESPUÉS del scheduling ==="
        # Esperar un poco para que se registren todos los logs
        sleep 2

        # Contar operaciones DESPUÉS del scheduling.  --since=1m para obtener sólo los últimos
        list_after=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | \
        grep -c -E "list.*pods|List.*pods|get.*pods|Get.*pods|watching|Watching" 2>/dev/null || echo "0")

        # LIMPIAR el valor - eliminar saltos de línea y espacios
        list_after=$(echo "$list_after" | tr -d '\n' | tr -d ' ' | tr -d '\r')

        # Si está vacío, poner 0
        if [[ -z "$list_after" ]]; then
            list_after=0
        fi

        # Si sigue siendo 0, contar líneas totales recientes como estimación
        if [[ "$list_after" -eq "0" ]]; then
            list_after=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | wc -l 2>/dev/null || echo "0")
            list_after=$(echo "$list_after" | tr -d '\n' | tr -d ' ' | tr -d '\r')
            [[ -z "$list_after" ]] && list_after=0
        fi

        # Calcular diferencia (las operaciones durante el scheduling)
        list_ops=$((list_after - list_before))

        # Asegurar que no sea negativo
        if [[ $list_ops -lt 0 ]]; then
            list_ops=0
        fi
        echo "Operaciones LIST DESPUÉS: $list_after"
        echo "Operaciones LIST DURANTE scheduling: $list_ops"
    else
        echo "No se pudo encontrar el pod del scheduler para contar operaciones LIST"
    fi

    echo "LIST Ops (scheduler): $list_ops"

    # 7. Número de re-intentos del scheduler
    local implicit_retries=0
    local retry_count=0
    if [[ -n "$scheduler_pod" ]]; then
        # a. Total de intentos de scheduling
        # Obtener y limpiar total_attempts
        total_attempts=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
             grep -c "Attempting to schedule pod: $NAMESPACE/$POD_NAME" || echo "0")

        total_attempts=$(clean_numeric_value "$total_attempts")

        # b. Obtener y limpiar successful_schedules
        successful_schedules=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
              grep -c "Bound $NAMESPACE/$POD_NAME" || echo "0")
        successful_schedules=$(clean_numeric_value "$successful_schedules")

        echo "total_attempts: [$total_attempts]"
        echo "successful_schedules: [$successful_schedules]"

        # c. Calcular reintentos
        retry_count=$(kubectl -n kube-system logs "$scheduler_pod" | grep $pod_name 2>/dev/null | \
            grep -c "retry\|Retry\|retrying\|error\|Error" || echo "0")
        # Limpiar cualquier salto de línea
        retry_count=$(echo "$retry_count" | tr -d '\n' | tr -d ' ')

        # Reintentos implícitos: intentos - éxitos
        echo "total_attempts: $total_attempts"
        echo "successful_schedules): $successful_schedules)"
        implicit_retries=$((total_attempts - successful_schedules))
        echo "Re-intentos implícitos (total - exitosos): $implicit_retries"
     fi
     echo "Re-intentos explícitos: $retry_count"
     echo "Re-intentos implícitos (total - exitosos): $implicit_retries"

    # 8. Eventos de binding
    local scheduler_events=0
    # Limpiar pod previo
    kubectl delete pod $pod_name -n $NAMESPACE --ignore-not-found=true
    sleep 3

    if [[ -n "$scheduler_pod" ]]; then
        scheduler_events=$(kubectl -n kube-system logs "$scheduler_pod" | grep $pod_name 2>/dev/null | \
            grep -c "Bound.*$pod_name\|Scheduled.*$pod_name" || echo "0")
        scheduler_events=$(echo "$scheduler_events" | tr -d '\n' | tr -d ' ')
    fi

    echo "Eventos de binding para $pod_name: $scheduler_events"

    # 3. Latencia Pending -> Running. Lo pasamos aqui para forzar la  métrica. Volvemos a borrar el Pod y crearlo deneuvo 
    # para modificar los cambios de estado y ver el tiempo que le cuesta llegar a running

    # Limpiar pod previo
    kubectl delete pod $pod_name -n $NAMESPACE --ignore-not-found=true
    sleep 3
    # Volvems a arrancar el Pod para cambiar el estado
    kubectl apply -f $yaml_file -n $NAMESPACE
    echo "Pod $pod_name aplicado"

    # Esperar a que el pod esté listo
    kubectl wait --for=condition=Ready pod/$pod_name -n $NAMESPACE --timeout=120s

    # Pequeña pausa para logs
    sleep 5
    # Notar que lso sleeps no afectan al Pod. En neustro caso es 0 porque  los Pods no tienen mucha carga y el estado a running es rápido
    local creation_time=$(kubectl -n $NAMESPACE get pod $pod_name -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    local start_time=$(kubectl -n $NAMESPACE get pod $pod_name -o jsonpath='{.status.startTime}' 2>/dev/null)

    local latency_pending_running="N/A"
    if [[ -n "$creation_time" && -n "$start_time" ]]; then
        local creation_sec=$(date -d "$creation_time" +%s 2>/dev/null)
        local start_sec=$(date -d "$start_time" +%s 2>/dev/null)
        if [[ $creation_sec -gt 0 && $start_sec -gt 0 ]]; then
            latency_pending_running=$((start_sec - creation_sec))
        fi
    fi
    echo "Latencia Pending→Running: $latency_pending_running s"



    # Guardar métricas
    if [[ "$pod_name" == "test-pod" ]]; then
        METRICS_TEST_POD["latency"]=$scheduler_latency
        METRICS_TEST_POD["latency_pending_running"]=$latency_pending_running
        METRICS_TEST_POD["list_ops"]=$list_ops
        METRICS_TEST_POD["cpu"]=$avg_cpu
        METRICS_TEST_POD["mem"]=$avg_mem
        METRICS_TEST_POD["pull_start_latency"]=$pull_start_latency
        METRICS_TEST_POD["retries"]=$retry_count
        METRICS_TEST_POD["implicit_retries"]=$implicit_retries
        METRICS_TEST_POD["events"]=$scheduler_events
    else
        METRICS_NGINX_POD["latency"]=$scheduler_latency
        METRICS_NGINX_POD["latency_pending_running"]=$latency_pending_running
        METRICS_NGINX_POD["list_ops"]=$list_ops
        METRICS_NGINX_POD["cpu"]=$avg_cpu
        METRICS_NGINX_POD["mem"]=$avg_mem
        METRICS_NGINX_POD["pull_start_latency"]=$pull_start_latency
        METRICS_NGINX_POD["retries"]=$retry_count
        METRICS_NGINX_POD["implicit_retries"]=$implicit_retries
        METRICS_NGINX_POD["events"]=$scheduler_events
    fi

    return 0
}

# Función para análisis detallado de scheduling QUE USA LAS MÉTRICAS DE run_improved_latency_test
analyze_scheduling_detailed() {
    local pod_name=$1
    local namespace=$2
    local test_name=$3
    # Obtener el pod del scheduler
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')

    echo ""
    echo "=== ANÁLISIS DETALLADO (USANDO MÉTRICAS): $test_name ==="

    # Obtener métricas de los arrays globales
    local scheduling_latency="N/A"
    local pending_running_latency="N/A"
    local pull_start_latency="N/A"
    local cpu_usage="N/A"
    local mem_usage="N/A"
    local list_ops="N/A"
    local retry_count="N/A"

    if [[ "$pod_name" == "test-pod" ]]; then
        scheduling_latency=${METRICS_TEST_POD["latency"]}
        pending_running_latency=${METRICS_TEST_POD["latency_pending_running"]}
        pull_start_latency=${METRICS_TEST_POD["pull_start_latency"]}
        cpu_usage=${METRICS_TEST_POD["cpu"]}
        mem_usage=${METRICS_TEST_POD["mem"]}
        list_ops=${METRICS_TEST_POD["list_ops"]}
        retry_count=${METRICS_TEST_POD["retries"]}
        events=${METRICS_TEST_POD["events"]}
    else
        scheduling_latency=${METRICS_NGINX_POD["latency"]}
        pending_running_latency=${METRICS_NGINX_POD["latency_pending_running"]}
        pull_start_latency=${METRICS_NGINX_POD["pull_start_latency"]}
        cpu_usage=${METRICS_NGINX_POD["cpu"]}
        mem_usage=${METRICS_NGINX_POD["mem"]}
        list_ops=${METRICS_NGINX_POD["list_ops"]}
        retry_count=${METRICS_NGINX_POD["retries"]}
        events=${METRICS_NGINX_POD["events"]}
    fi

    # Throughput reciente
    local recent_schedules=$(kubectl -n kube-system logs -l app=$SCHEDULER_NAME --since=5m 2>/dev/null \
                              | grep "$pod_name" \
                              | grep -c "Bound")

    # Si recent_schedules está vacío, usar 0
    recent_schedules=${recent_schedules:-0}

    echo "recent_schedules: [$recent_schedules]"

    local throughput=$((recent_schedules * 12))  # pods por hora

    # Tasa de éxito

    local total_attempts=0
    local successful_schedules=0
    local success_rate="N/A"

    # Obtener y limpiar total_attempts
    total_attempts=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
        grep -c "Attempting to schedule pod: $NAMESPACE/$POD_NAME" || echo "0")

    total_attempts=$(clean_numeric_value "$total_attempts")

    # Obtener y limpiar successful_schedules
    successful_schedules=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
        grep -c "Bound $NAMESPACE/$POD_NAME" || echo "0")
    successful_schedules=$(clean_numeric_value "$successful_schedules")

    echo "total_attempts: [$total_attempts]"
    echo "successful_schedules: [$successful_schedules]"

    if [[ $total_attempts -gt 0 ]]; then
        # Usar awk para evitar problemas con bc
        success_rate=$(awk "BEGIN {printf \"%.2f\", $successful_schedules * 100 / $total_attempts}" 2>/dev/null || echo "0")
    else
        success_rate="0"
    fi


    # Estado del cluster
    local cluster_state=$(get_cluster_state)


    # Carga compuesta (solo si tenemos latencia numérica)
    local composite_load="N/A"
    if [[ "$scheduling_latency" =~ ^[0-9]+$ ]]; then
        composite_load=$(calculate_composite_metrics "$scheduling_latency" "$cpu_usage" "$mem_usage" "$success_rate")
    fi

    # Mostrar resultados
    echo "  - Latencia Scheduling: ${scheduling_latency}s"
    echo "  - Latencia Pending→Running: ${pending_running_latency}s"
    echo "  - Latencia Pull→Start: ${pull_start_latency}s"
    echo "  - Re-intentos scheduler: $retry_count"
    echo "  - Throughput: $throughput pods/h"
    echo "  - Tasa de éxito: ${success_rate}%"
    echo "  - CPU: $cpu_usage, Mem: $mem_usage"
    echo "  - Operaciones LIST: $list_ops"
    echo "  - Estado cluster: $cluster_state"
    echo "  - Eventos: $events"

    # Solo mostrar carga compuesta si es numérica
    if [[ "$composite_load" != "N/A" ]]; then
        echo "  - Carga compuesta: $composite_load/100"

        # Interpretación de carga (CORREGIDO - sin error de "too many arguments")
        if [[ "$composite_load" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            if (( $(echo "$composite_load < 30" | bc -l 2>/dev/null) )); then
                echo "  - CARGA: BAJA ✅"
            elif (( $(echo "$composite_load < 70" | bc -l 2>/dev/null) )); then
                echo "  - CARGA: MODERADA ⚠️"
            else
                echo "  - CARGA: ALTA ❌"
            fi
        else
            echo "  - CARGA: NO DISPONIBLE"
        fi
    else
        echo "  - Carga compuesta: N/A"
        echo "  - CARGA: NO DISPONIBLE"
    fi

    # Registrar métricas en CSV
    record_metrics "$test_name" "$pod_name" "$scheduling_latency" "N/A" "N/A" "$pending_running_latency" \
                   "$pull_start_latency" "$cpu_usage" "$mem_usage" "$list_ops" "$success_rate" "$composite_load" "$cluster_state"
}


# Función wait_for_image. Espera cargar la imagen del schedulker en el clúster 
wait_for_image() {
    IMAGE=$1
    NODE=$2
    TIMEOUT=${3:-60}
    INTERVAL=${4:-2}

    IMAGE_BASENAME="${IMAGE##*/}"
    START=$(date +%s)
    echo -n "Esperando imagen $IMAGE en nodo $NODE "
    while true; do
        if docker exec "$NODE" crictl images | awk '{print $1":"$2}' | grep -q "$IMAGE_BASENAME"; then
            echo " ✔"
            break
        fi
        NOW=$(date +%s)
        ELAPSED=$((NOW-START))
        if (( ELAPSED > TIMEOUT )); then
            echo
            echo "ERROR: Imagen $IMAGE no cargada en $NODE después de $TIMEOUT s"
            exit 1
        fi
        echo -n "."
        sleep "$INTERVAL"
    done
}

# Función existente limpiar_y_cargar_imagen. Carga el dockerfile del scheduler y la imagen dentro del clúster
limpiar_y_cargar_imagen() {
    IMAGE_NAME=$1
    LOCAL=$2
    TIMEOUT=60
    INTERVAL=2

    echo "=== Limpiando imagen $IMAGE_NAME ==="
    docker rmi -f $IMAGE_NAME >/dev/null 2>&1 || true

    NODES=$(kind get nodes --name "$CLUSTER_NAME")

    for NODE in $NODES; do
        docker exec "$NODE" crictl rmi $IMAGE_NAME >/dev/null 2>&1 || true
    done

    if [[ "$LOCAL" == "local" ]]; then
        echo "=== Construyendo imagen $IMAGE_NAME ==="
        docker build --no-cache -t $IMAGE_NAME .
    else
        echo "=== Pull de imagen $IMAGE_NAME ==="
        docker pull $IMAGE_NAME
    fi

    echo "=== Cargando imagen $IMAGE_NAME en Kind ==="
    kind load docker-image $IMAGE_NAME --name $CLUSTER_NAME

    for NODE in $NODES; do
        wait_for_image "$IMAGE_NAME" "$NODE" "$TIMEOUT" "$INTERVAL"
    done

    echo "=== Imagen $IMAGE_NAME disponible en todos los nodos ==="
}

# Función principal
main() {
    echo "=== INICIO TEST COMPLETO SCHEDULER ==="
    echo "Resultados en: $RESULTS_FILE"

    # (MANTENER TU CONFIGURACIóN INICIAL EXISTENTE)
    read -p "¿Deseas eliminar el cluster $CLUSTER_NAME y empezar de cero? [y/N]: " respuesta
    respuesta=${respuesta,,}

    if [[ "$respuesta" == "y" || "$respuesta" == "yes" ]]; then
        echo "=== Eliminando cluster $CLUSTER_NAME ==="
        kind delete cluster --name "$CLUSTER_NAME"
        echo "=== Cluster eliminado ==="
    fi

    if ! kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        echo "=== Creando cluster $CLUSTER_NAME ==="
        kind create cluster --name "$CLUSTER_NAME"
        echo "=== Esperando a que el nodo control-plane esté Ready ==="
        echo -n "Esperando nodo Ready"
        until kubectl get node sched-lab-control-plane -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; do
            echo -n "."
            sleep 2
        done
        echo " listo!"
    else
        echo "Cluster $CLUSTER_NAME ya existe, se continuará con el existente"
    fi

    kubectl cluster-info
    kubectl get nodes

    # Limpiar recursos antiguos
    kubectl delete deployment my-scheduler -n kube-system --ignore-not-found
    kubectl delete pod test-pod -n $NAMESPACE --ignore-not-found 2>/dev/null || true
    kubectl delete pod test-nginx-pod -n $NAMESPACE --ignore-not-found 2>/dev/null || true

    # Crear namespace si no existe
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "=== Creando namespace $NAMESPACE ==="
        kubectl create namespace "$NAMESPACE"
    fi

    # Construir y cargar scheduler
    limpiar_y_cargar_imagen "$SCHED_IMAGE" local

    # Desplegar scheduler
    echo "=== Desplegando scheduler ==="
    kubectl apply -f rbac-deploy.yaml
    kubectl rollout status deployment/my-scheduler -n kube-system --timeout=120s

    # Instalar metrics-server si no existe
    if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
        echo "=== Instalando metrics-server ==="
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        kubectl patch deployment metrics-server -n kube-system --type='json' \
            -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
        kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system
    fi

    # Esperar a que metrics-server esté listo
    echo "=== Esperando a que metrics-server esté listo ==="
    sleep 30

    # USAR LA FUNCIÓN CORRECTA: run_improved_latency_test en lugar de run_manual_latency_test
    echo "=== Lanzando test-pod ==="
    run_improved_latency_test "test-pod" "test-pod.yaml" "test_basic"
    analyze_scheduling_detailed "test-pod" "$NAMESPACE" "test_basic_detailed"


    # Test con nginx
    limpiar_y_cargar_imagen "$NGINX_IMAGE" remoto
    echo "=== Lanzando test-nginx-pod ==="
    run_improved_latency_test "test-nginx-pod" "test_nginx_pod.yaml" "test_nginx"

    # Análisis detallado usando las métricas ya calculadas
    analyze_scheduling_detailed "test-nginx-pod" "$NAMESPACE" "test_nginx_detailed"


    # Resumen final con tabla
    echo ""
    echo "=== RESUMEN FINAL ==="
    echo "Métricas guardadas en: $RESULTS_FILE"
    echo ""
    echo "=== COMPARATIVA FINAL (MÉTRICAS) ==="
    # Definir los anchos de columna
    col1=15   # Pod
    col2=12   # LatPolling(s)
    col3=20   # LatPending->Running(s)
    col4=6    # LIST
    col5=8    # CPU
    col6=8    # Mem
    col7=14   # Pull->Start(s)
    col8=10   # Retries
    col9=8    # Events
    col10=18  # Implicits_Retries

    # Imprimir encabezados
    printf "%-${col1}s | %-${col2}s | %-${col3}s | %-${col4}s | %-${col5}s | %-${col6}s | %-${col7}s | %-${col8}s | %-${col9}s | %-${col10}s\n" \
        "Pod" "LatPolling(s)" "LatPending->Run(s)" "LIST" "CPU" "Mem" "Pull->Start(s)" "Retries" "Events" "Implicits_Retries"
    # Línea separadora
    printf "%-${col1}s-+-%-${col2}s-+-%-${col3}s-+-%-${col4}s-+-%-${col5}s-+-%-${col6}s-+-%-${col7}s-+-%-${col8}s-+-%-${col9}s-+-%-${col10}s\n" \
        "---------------" "------------" "--------------------" "------" "--------" "--------" "--------------" "----------" "--------" "------------------"

    # Imprimir fila para test-pod
    printf "%-${col1}s | %-${col2}s | %-${col3}s | %-${col4}s | %-${col5}s | %-${col6}s | %-${col7}s | %-${col8}s | %-${col9}s | %-${col10}s\n" \
        "test-pod" \
        "${METRICS_TEST_POD["latency"]}" \
        "${METRICS_TEST_POD["latency_pending_running"]}" \
        "${METRICS_TEST_POD["list_ops"]}" \
        "${METRICS_TEST_POD["cpu"]}" \
        "${METRICS_TEST_POD["mem"]}" \
        "${METRICS_TEST_POD["pull_start_latency"]}" \
        "${METRICS_TEST_POD["retries"]}" \
        "${METRICS_TEST_POD["events"]}" \
        "${METRICS_TEST_POD["implicit_retries"]}"

    # Imprimir fila para test-nginx-pod
    printf "%-${col1}s | %-${col2}s | %-${col3}s | %-${col4}s | %-${col5}s | %-${col6}s | %-${col7}s | %-${col8}s | %-${col9}s | %-${col10}s\n" \
        "test-nginx-pod" \
        "${METRICS_NGINX_POD["latency"]}" \
        "${METRICS_NGINX_POD["latency_pending_running"]}" \
        "${METRICS_NGINX_POD["list_ops"]}" \
        "${METRICS_NGINX_POD["cpu"]}" \
        "${METRICS_NGINX_POD["mem"]}" \
        "${METRICS_NGINX_POD["pull_start_latency"]}" \
        "${METRICS_NGINX_POD["retries"]}" \
        "${METRICS_NGINX_POD["events"]}" \
        "${METRICS_NGINX_POD["implicit_retries"]}"

    echo ""
    echo "=== TEST COMPLETADO ==="
}

# === EJECUCIÓN PRINCIPAL ===
main "$@"
