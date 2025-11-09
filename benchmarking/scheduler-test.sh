#!/bin/bash
set -e

# ========================================
# CONFIGURACIÓN GLOBAL
# ========================================
SCHED_IMPL=${1:-polling}
NUM_PODS=${2:-20}
NAMESPACE="test-scheduler"
SCHEDULER_NAME="my-scheduler"
RESULTS_DIR="./${SCHED_IMPL}/metrics"
TEMP_DIR="/tmp/pod_metrics_$$"
RESULTS_JSON="${RESULTS_DIR}/scheduler_metrics_$(date +%Y%m%d_%H%M%S).json"
METRICS_DIR="./${SCHEDULER_NAME}/metrics"
POD_TYPES=("cpu-heavy" "ram-heavy" "nginx" "test-basic")

mkdir -p "$METRICS_DIR" "$RESULTS_DIR" "$TEMP_DIR"

RESULTS_FILE="$METRICS_DIR/results.csv"
echo "timestamp,pod_name,latency,latency_pending_running,pull_start_latency,cpu_usage,mem_usage,list_ops,retries,implicit_retries,events" > "$RESULTS_FILE"

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
    local latency=$(kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" \
        --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{"\n"}{end}' 2>/dev/null \
        | grep -E 'Pulling|Started' \
        | awk '/Pulling/ {pull=$1} /Started/ {start=$1; print (mktime(gensub(/[-:T]/," ","g",start)) - mktime(gensub(/[-:T]/," ","g",pull)))}')
    [[ -z "$latency" ]] && echo "N/A" || echo "$latency"
}

get_pending_running_latency() {
    local pod_name=$1
    local namespace=$2
    local creation_time=$(kubectl -n $namespace get pod $pod_name -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    local start_time=$(kubectl -n $namespace get pod $pod_name -o jsonpath='{.status.startTime}' 2>/dev/null)
    if [[ -n "$creation_time" && -n "$start_time" ]]; then
        local creation_sec=$(date -d "$creation_time" +%s 2>/dev/null)
        local start_sec=$(date -d "$start_time" +%s 2>/dev/null)
        echo $((start_sec - creation_sec))
    else
        echo "N/A"
    fi
}

get_scheduler_resources_avg() {
    local cpu_sum=0 mem_sum=0 samples=0
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')
    for i in {1..3}; do
        if [[ -n "$scheduler_pod" ]]; then
            local top_output=$(kubectl top pod "$scheduler_pod" -n kube-system 2>/dev/null || echo "")
            if [[ $(echo "$top_output" | wc -l) -gt 1 ]]; then
                local cpu=$(echo "$top_output" | awk 'NR>1 {print $2}' | sed 's/m//')
                local mem=$(echo "$top_output" | awk 'NR>1 {print $3}' | sed 's/Mi//')
                [[ "$cpu" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] && ((cpu_sum+=cpu, mem_sum+=mem, samples++))
            fi
        fi
        sleep 1
    done
    [[ $samples -gt 0 ]] && echo "$((cpu_sum/samples))m $((mem_sum/samples))Mi" || echo "0m 0Mi"
}

get_list_ops() {
    local pod_name=$1
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')
    local list_ops=0
    if [[ -n "$scheduler_pod" ]]; then
        local list_before=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep -c $pod_name || echo "0")
        sleep 2
        local list_after=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep -c $pod_name || echo "0")
        list_ops=$((list_after - list_before))
        ((list_ops<0)) && list_ops=0
    fi
    echo "$list_ops"
}

get_scheduler_attempts_events() {
    local pod_name=$1
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')
    local retries=0 implicit_retries=0 events=0
    if [[ -n "$scheduler_pod" ]]; then
        local total_attempts=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h | grep -c "Attempting to schedule pod: $NAMESPACE/$pod_name" || echo "0")
        local successful=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h | grep -c "Bound $NAMESPACE/$pod_name" || echo "0")
        total_attempts=$(clean_numeric_value "$total_attempts")
        successful=$(clean_numeric_value "$successful")
        implicit_retries=$((total_attempts - successful))
        retries=$(kubectl -n kube-system logs "$scheduler_pod" | grep -c "$pod_name" | grep -c -E "retry|Retry|error|Error" || echo "0")
        events=$(kubectl -n kube-system logs "$scheduler_pod" | grep -c -E "Bound.*$pod_name|Scheduled.*$pod_name" || echo "0")
    fi
    echo "$retries $implicit_retries $events"
}

record_metrics() {
    local pod_name=$1 latency=$2 latency_pending_running=$3 pull_start_latency=$4 cpu=$5 mem=$6 \
          list_ops=$7 retries=$8 implicit_retries=$9 events=${10}
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$timestamp,$pod_name,$latency,$latency_pending_running,$pull_start_latency,$cpu,$mem,$list_ops,$retries,$implicit_retries,$events" >> "$RESULTS_FILE"
}

# ========================================
# FUNCIONES DE POD
# ========================================

run_pod_test() {
    local pod_name=$1 yaml_file=$2 namespace=$3
    echo "=== Ejecutando test de pod: $pod_name ==="
    kubectl delete pod $pod_name -n $namespace --ignore-not-found=true
    sleep 2
    local t0_sec=$(date -u +%s)
    kubectl apply -f "$yaml_file" -n $namespace
    kubectl wait --for=condition=Ready pod/$pod_name -n $namespace --timeout=120s
    sleep 2

    local latency_pending_running=$(get_pending_running_latency "$pod_name" "$namespace")
    local pull_start_latency=$(get_pull_start_latency "$pod_name" "$namespace")
    read -r avg_cpu avg_mem <<< "$(get_scheduler_resources_avg)"
    local list_ops=$(get_list_ops "$pod_name")
    read -r retries implicit_retries events <<< "$(get_scheduler_attempts_events "$pod_name")"
    local latency=$(( $(date -u +%s) - t0_sec ))

    record_metrics "$pod_name" "$latency" "$latency_pending_running" "$pull_start_latency" "$avg_cpu" "$avg_mem" "$list_ops" "$retries" "$implicit_retries" "$events"
    echo "=== Test finalizado para pod: $pod_name ==="
}

write_pod_metrics_to_temp() {
    local pod_name=$1 pod_type=$2 latency=$3 pending_latency=$4 pull_latency=$5 cpu=$6 mem=$7 \
          list_ops=$8 retries=$9 implicit_retries=${10} events=${11}
    local temp_file="${TEMP_DIR}/${pod_name}.json"
    jq -n \
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
}

measure_and_save_pod_metrics() {
    local pod_name=$1 pod_type=$2 yaml_file=$3 namespace=$4
    kubectl delete pod "$pod_name" -n "$namespace" --ignore-not-found=true
    sleep 1
    local t0=$(date +%s)
    kubectl apply -f "$yaml_file" -n "$namespace"
    kubectl wait --for=condition=Ready pod/"$pod_name" -n "$namespace" --timeout=120s || true
    sleep 1

    local latency=$(( $(date +%s) - t0 ))
    local pending_latency=$(get_pending_running_latency "$pod_name" "$namespace")
    local pull_latency=$(get_pull_start_latency "$pod_name" "$namespace")
    read -r cpu mem <<< "$(get_scheduler_resources_avg)"
    local list_ops=$(get_list_ops "$pod_name")
    read -r retries implicit_retries events <<< "$(get_scheduler_attempts_events "$pod_name")"

    write_pod_metrics_to_temp "$pod_name" "$pod_type" "$latency" "$pending_latency" "$pull_latency" "$cpu" "$mem" "$list_ops" "$retries" "$implicit_retries" "$events"
    echo "Métricas guardadas para $pod_name"
}

# ========================================
# EJECUCIÓN PARALELA
# ========================================

run_all_tests_parallel() {
    declare -a pids=()
    for pod_type in "${POD_TYPES[@]}"; do
        for i in $(seq 1 "$NUM_PODS"); do
            pod_name="${pod_type}-pod-${i}"
            yaml_file="./yamls/${pod_type}.yaml"
            measure_and_save_pod_metrics "$pod_name" "$pod_type" "$yaml_file" "$NAMESPACE" &
            pids+=($!)
        done
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
}

# ========================================
# CONSOLIDACIÓN Y JSON
# ========================================

consolidate_metrics_with_jq() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local json_array="[]"
    for temp_file in "$TEMP_DIR"/*.json; do
        [[ -f "$temp_file" ]] && json_array=$(echo "$json_array" | jq ". + [$(cat "$temp_file")]")
    done

    jq -n \
        --arg timestamp "$timestamp" \
        --arg scheduler "$SCHED_IMPL" \
        --argjson pods_per_type "$NUM_PODS" \
        --argjson pod_metrics "$json_array" \
        '{
            test_timestamp: $timestamp,
            scheduler_implementation: $scheduler,
            pods_per_type: $pods_per_type,
            pod_metrics: $pod_metrics,
            aggregate_metrics: {}
        }' > "$RESULTS_JSON"

    echo "JSON final generado: $RESULTS_JSON"
}

# ========================================
# CÁLCULO DE MEDIAS
# ========================================

calculate_metrics_means() {
    echo "=== Calculando medias de métricas ==="
    awk -F, '
    NR>1 {
        count++; sum_latency+=$3; sum_pending+=$4; sum_pull+=$5; sum_cpu+=$6; sum_mem+=$7;
        sum_list+=$8; sum_retries+=$9; sum_implicit+=$10; sum_events+=$11
    }
    END {
        if(count>0){
            print "Promedio Latencia: " sum_latency/count
            print "Promedio Pending->Running: " sum_pending/count
            print "Promedio Pull->Start: " sum_pull/count
            print "Promedio CPU: " sum_cpu/count
            print "Promedio MEM: " sum_mem/count
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
# EJECUCIÓN PRINCIPAL
# ========================================

run_all_tests_parallel
calculate_metrics_means
consolidate_metrics_with_jq
