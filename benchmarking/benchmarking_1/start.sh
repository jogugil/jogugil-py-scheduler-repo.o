#!/bin/bash
# ============================================================
#   Script desarrollado principalmente por:
#     José Javier Gutiérrez Gil (jogugil@gmail.com)
#     Javier Díaz León (JavierDiazL - javidi2001@gmail.com)
#     Francesc (cescdovi@gmail.com)
#
#   Este script ha sido creado y mantenido con aportaciones conjuntas,
#   y se distribuye bajo la Apache License 2.0.
#   Puedes consultar la licencia completa en el archivo LICENSE o en:
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   La autoría y prioridad de esta obra quedan acreditadas
#   mediante su registro en GitHub.
#
#   El contenido documental, imágenes y archivos PDF asociados a este proyecto
#   se encuentran bajo la licencia Creative Commons
#   Attribution-NonCommercial 4.0 International (CC BY-NC 4.0):
#       https://creativecommons.org/licenses/by-nc/4.0/
# ============================================================
set -euo pipefail

# ========================================
# CONFIGURACIÓN
# ========================================
CLUSTER_NAME="sched-lab"
NAMESPACE="test-scheduler"
POD_IMAGE="nginx:latest"
KINND_CLUSTER="kind-cluster.yaml" #Es el manifiesto del clúster por defecto que crea el script cuando arranca. Está en el diorectorio raiz.

#------------------------------------
DEFAULT_WORKERS=3
MAX_TOTAL_PODS=4
MAX_PARALLEL_PODS=2

# Parámetros de ejecución (PAra control de lo que se pasa al script como argumentos)
WORKERS=${1:-$DEFAULT_WORKERS}
TOTAL_PODS=${2:-$MAX_TOTAL_PODS}
MAX_CONCURRENT_PODS=${3:-$MAX_PARALLEL_PODS}
#------------------------------------

# Carpeta donde se generarán los manifiestos temporales o de recreación
MANIFEST_DIR="./recreate_cluster"
mkdir -p "$MANIFEST_DIR"
KIND_CONFIG="kind-<cluster>-<timestamp>.yaml" # Es el manifiesto para poder recrear un cúster de forma dinámica

# ========================================
# FUNCIONES DE UTILIDAD
# ========================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1: $2"
}

error() {
    log "ERROR" "$1"
    exit 1
}

info() {
    log "INFO" "$1"
}

debug() {
    log "DEBUG" "$1"
}

warn() {
    log "WARN" "$1"
}
safe_run() {
    local description="$1"
    shift
    echo "[SAFE] Ejecutando: $*"
    "$@" || {
        echo "[SAFE] Advertencia: '$*' falló, pero continuamos"
        true
    }
}

# ========================================
# FUNCIONES DE GESTIÓN DE PODS - COMPLETAMENTE CORREGIDAS
# ========================================
load_image_in_cluster() {
    local CLUSTER_NAME=${1:-sched-lab}
    local DIRS=("cpu-heavy" "ram-heavy" "nginx" "test-basic")

    echo "=== Construyendo y cargando imágenes locales en el cluster '$CLUSTER_NAME' ==="

    for dir in "${DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            # Asumimos que el Dockerfile genera una imagen con el mismo nombre que el directorio
            IMAGE_NAME="$dir:latest"
            echo "Construyendo imagen $IMAGE_NAME desde $dir..."
            docker build -t "$IMAGE_NAME" "$dir"

            # Obtener lista de nodos del cluster
            NODES=$(kind get nodes --name "$CLUSTER_NAME"| grep -v "control-plane")

            for node in $NODES; do
                echo "Cargando imagen $IMAGE_NAME en nodo $node..."
                kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" --nodes "$node"
            done

            echo "Imagen $IMAGE_NAME cargada en todos los nodos."
        else
            echo "Directorio $dir no existe, se omite."
        fi
    done

    echo "=== Todas las imágenes han sido construidas y cargadas ==="
}

show_pods_by_node() {
    echo "=== PODS AGRUPADOS POR NODO ==="

    # Verificar si hay pods
    if ! kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        echo "No hay pods en el namespace $NAMESPACE"
        return 1
    fi

    # Obtener todos los nodos únicos con pods
    local nodes
    nodes=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$' || true)

    if [ -z "$nodes" ]; then
        echo "No se pudieron obtener los nodos"
        return 1
    fi

    # Mostrar pods por cada nodo
    local node_count=0
    for node in $nodes; do
        echo ""
        echo "--- NODO: $node ---"
        printf "%-25s %-12s %-15s\n" "POD" "ESTADO" "IP"
        echo "------------------------- ------------ ---------------"

        kubectl get pods -n "$NAMESPACE" --field-selector spec.nodeName="$node" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.podIP}{"\n"}{end}' 2>/dev/null | \
        while read -r name phase ip; do
            if [ -n "$name" ]; then
                printf "%-25s %-12s %-15s\n" "$name" "$phase" "$ip"
            fi
        done

        node_count=$((node_count + 1))
    done

    echo ""
    echo "Total de nodos con pods: $node_count"
    return 0
}

# FUNCIÓN SELECT_POD_MENU COMPLETAMENTE CORREGIDA
select_pod_menu() {
    local action="$1"
    local pod_list count selection selected_pod

    echo " ---> $action" >&2
    echo "" >&2
    echo "=== SELECCIONAR POD PARA $action ===" >&2

    # Obtener lista de pods
    pod_list=$(kubectl get pods -n "$NAMESPACE" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName" --no-headers 2>/dev/null)

    if [[ -z "$pod_list" ]]; then
        echo "No hay pods disponibles en el namespace $NAMESPACE" >&2
        return 1
    fi

    # Mostrar lista numerada
    count=0
    echo "" >&2
    echo "Pods disponibles:" >&2
    echo "=============================================" >&2
    printf "%-30s %-12s %-15s\n" "NOMBRE" "ESTADO" "NODO" >&2
    echo "---------------------------------------------" >&2
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        count=$((count + 1))
        echo "$count. $line" >&2
    done <<< "$pod_list"

    if [[ $count -eq 0 ]]; then
        echo "No hay pods disponibles" >&2
        return 1
    fi

    # Leer selección del usuario
    echo "" >&2
    read -p "Introduce el número del pod (1-$count): " selection >&2

    # Validar selección
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
        echo "Error: selección inválida" >&2
        return 1
    fi

    # Obtener nombre del pod
    selected_pod=$(echo "$pod_list" | sed -n "${selection}p" | awk '{print $1}')

    if [[ -z "$selected_pod" ]]; then
        echo "Error: no se pudo obtener el nombre del pod" >&2
        return 1
    fi

    # Validar que el pod realmente existe
    if ! kubectl get pod "$selected_pod" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "Error: el pod '$selected_pod' no existe" >&2
        return 1
    fi

    # Trazas por stderr
    echo "Pod seleccionado: $selected_pod" >&2

    # Valor devuelto por stdout
    echo "$selected_pod"
}

# FUNCIONES INTERACTIVAS CORREGIDAS
show_pod_logs_interactive() {
    echo ">>> Entrando en show_pod_logs_interactive"
    echo ""
    echo "=== MOSTRAR LOGS DE POD ==="

    local pod_name
    pod_name=$(select_pod_menu "LOGS")
    echo "$pod_name"

    if [[ $? -ne 0 ]] || [[ -z "$pod_name" ]]; then
        echo "Operación cancelada o no hay pods disponibles"
        return 1
    fi

echo ""
echo "=== MOSTRANDO LOGS DEL POD: $pod_name ==="
echo "Presiona Ctrl+C para detener"
echo "----------------------------------------"

echo ""
echo "Opciones de visualización:"
echo "1. Últimas 100 líneas"
echo "2. Logs desde el inicio (24h)"
echo "3. Últimas 50 líneas (default)"
echo ""

read -p "Selecciona opción [1-4]: " log_option

case $log_option in
    1)
        echo "Mostrando últimas 100 líneas:"
        kubectl logs "$pod_name" -n "$NAMESPACE" --tail=100
        ;;
    2)
        echo "Mostrando logs desde el inicio (24h):"
        kubectl logs "$pod_name" -n "$NAMESPACE" --since=24h
        ;;
    *)
        echo "Mostrando últimas 50 líneas:"
        kubectl logs "$pod_name" -n "$NAMESPACE" --tail=50
        ;;
esac

}

describe_pod_interactive() {
    echo ""
    echo "=== DESCRIBIR POD ==="

    local pod_name
    pod_name=$(select_pod_menu "DESCRIBIR")
    local result=$?

    if [ $result -ne 0 ] || [ -z "$pod_name" ]; then
        echo "Operación cancelada o no hay pods disponibles"
        return 1
    fi

    echo ""
    echo "=== DESCRIBIENDO POD: $pod_name ==="
    kubectl describe pod "$pod_name" -n "$NAMESPACE"
}

show_pod_events() {
    echo ""
    echo "=== EVENTOS DE POD ==="

    local pod_name
    pod_name=$(select_pod_menu "EVENTOS")
    local result=$?

    if [ $result -ne 0 ] || [ -z "$pod_name" ]; then
        echo "Operación cancelada o no hay pods disponibles"
        return 1
    fi

    echo ""
    echo "=== EVENTOS DEL POD: $pod_name ==="
    kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=$pod_name" --sort-by='.lastTimestamp' 2>/dev/null || echo "No se encontraron eventos para este pod"
}

show_performance_metrics() {
    echo "=== MÉTRICAS DE RENDIMIENTO ==="

    # Obtener información de recursos del cluster
    echo "--- RECURSOS DEL CLUSTER ---"
    kubectl top nodes 2>/dev/null || echo "Metrics-server no disponible"

    echo ""
    echo "--- USO DE RECURSOS POR POD ---"
    kubectl top pods -n "$NAMESPACE" 2>/dev/null || echo "No se pueden obtener métricas de pods"

    # Estadísticas de distribución
    echo ""
    echo "--- DISTRIBUCIÓN DE PODS POR NODO ---"
    kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | \
        sort | uniq -c | sort -nr || echo "No hay pods para mostrar distribución"

    # Mostrar información de capacidad de nodos
    echo ""
    echo "--- CAPACIDAD DE NODOS ---"
    kubectl get nodes -o custom-columns="NODE:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory" 2>/dev/null || echo "No se puede obtener información de nodos"
}

cleanup_cluster() {
    echo "=== LIMPIANDO CLUSTER COMPLETO ==="
    read -p "¿Estás seguro de que quieres eliminar el cluster '$CLUSTER_NAME'? (y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        kind delete cluster --name "$CLUSTER_NAME"
        info "Cluster $CLUSTER_NAME eliminado"
    else
        info "Operación cancelada"
    fi
}
show_host_cluster_status() {
    echo "=== Estado del host ==="
    # Memoria y CPU
    awk '/MemTotal|MemAvailable/ {printf "%s: %s MiB\n", $1, $2/1024}' /proc/meminfo
    echo "Núcleos disponibles: $(nproc)"
    echo "======================="

    # Pods agrupados por nodo
    echo "=== Pods por nodo ==="
    kubectl get pods -A -o wide | awk '{print $1, $2, $7, $8}'
    echo "======================="

    # Eventos recientes del cluster
    echo "=== Eventos del cluster (últimos 20) ==="
    kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp | tail -n 20
    echo "======================="

    # Scheduler y métricas
    echo "=== Scheduler y métricas ==="
    kubectl get pods -A -o wide | grep scheduler || echo "No se detecta scheduler corriendo."
    kubectl top nodes 2>/dev/null || echo "No hay métricas de nodos disponibles o metrics-server no instalado."
    echo "======================="
}

management_menu() {
    while true; do
        echo ""
        echo "=== MENÚ DE GESTIÓN DE PODS ==="
        echo "0. Estado del Host"
        echo "1. Mostrar pods agrupados por nodo"
        echo "2. Mostrar eventos del cluster"
        echo "3. Mostrar logs de un pod"
        echo "4. Describir un pod"
        echo "5. Mostrar eventos de un pod específico"
        echo "6. Mostrar eventos de un pods"         
        echo "7. Mostrar métricas de rendimiento"
        echo "8. Mostrar logs del scheduler"
        echo "9. Mostrar eventos del scheduler"
        echo "10. Mostrar pods por nodo con scheduler"
        echo "11. Describir scheduler y métricas"
        echo "12. Eliminar pods completados"
        echo "13. Limpiar todo el namespace"
        echo "14. Limpiar cluster completo"
        echo "15. Crear pods de prueba y scheduler"
        echo "16. Recrear el cluster completo" 
        echo "17. Validar cluster" 
        echo "18. Salir"

        read -p "Selecciona una opción (0-18): " option

        case $option in
            0)
                show_host_cluster_status
                ;;
            1)
                show_pods_by_node
                ;;
            2)
                echo "=== EVENTOS DEL CLUSTER ==="
                kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null || echo "No se pueden obtener eventos"
                ;;
            3)
                show_pod_logs_interactive
                ;;
            4)
                describe_pod_interactive
                ;;
            5)
                show_pod_events
                ;;
            6)
                show_pods_all_events
                ;;

            7)
                show_performance_metrics
                ;;
            8)
                show_scheduler_logs
                ;;
            9)
                show_scheduler_events
                ;;
            10)
                show_pods_by_node_with_scheduler
                ;;
            11)
                describe_scheduler
                ;;
             12)
                echo "=== ELIMINANDO PODS COMPLETADOS ==="
                cleanup_old_pods
                ;;
            13)
                echo "=== LIMPIANDO NAMESPACE ==="
                cleanup_namespace "$NAMESPACE"
                ;;
            14)
                cleanup_cluster
                ;;
            15)
                create_pods_and_scheduler
                ;;
            16)
                recreate_kind_cluster_default
                ;;
            17)
                echo "=== VERIFICAR CONFIGURACIÓN DE NODOS ==="
                configure_node_labels_and_taints "$CLUSTER_NAME"
                ;;
            18)
                return 0
                ;;
            *)
                echo "Opción inválida"
                ;;
        esac

        echo ""
        read -p "Presiona Enter para continuar..."
    done
}

# ========================================
# FUNCIONES BÁSICAS DEL CLUSTER
# ========================================
# a) Logs del scheduler
show_scheduler_logs() {
    local tail_lines follow

    echo "1. === LOGS DEL SCHEDULER 'my-scheduler' ==="

    # Preguntar cuántas líneas mostrar
    read -p "Número de líneas a mostrar (Enter para 50): " tail_lines
    tail_lines=${tail_lines:-50}

    kubectl logs -n kube-system -l app=my-scheduler --tail="$tail_lines"

    # Da los logs de han sido asignamos al nodo por my-scheduler
    #echo "2. === LOGS DEL SCHEDULER 'my-scheduler' ==="
    #SCHEDULER_POD=$(kubectl get pods -n kube-system -l app=my-scheduler -o jsonpath='{.items[0].metadata.name}')
    #kubectl logs -n kube-system "$SCHEDULER_POD"
}

# b) Eventos del scheduler
show_scheduler_events() {
    echo "=== EVENTOS DEL SCHEDULER 'my-scheduler' ==="

    # Sacamos el nombre del pod del scheduler
    local SCHEDULER_POD
    SCHEDULER_POD=$(kubectl get pods -n kube-system -l app=my-scheduler -o jsonpath='{.items[0].metadata.name}')

    # Mostramos los logs del scheduler
    echo "--- Logs del scheduler $SCHEDULER_POD ---"
    kubectl logs -n kube-system "$SCHEDULER_POD"

    # Sacamos el namespace donde crea los pods el scheduler
    local TARGET_NS="test-scheduler"  # Cambiar si tu scheduler crea pods en otro namespace

    echo "--- Eventos de los pods gestionados por $SCHEDULER_POD en namespace $TARGET_NS ---"
    kubectl get events -n "$TARGET_NS" --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp'
}

# c) Lista de pods por nodo mostrando quién los asignó
show_pods_by_node_with_scheduler() {
    echo "=== PODS AGRUPADOS POR NODO CON SCHEDULER en $NAMESPACE ==="
    for node in $(kubectl get nodes -o name | cut -d/ -f2); do
        echo "=== NODO: $node ==="
        kubectl get pods -n "$NAMESPACE" --field-selector spec.nodeName=$node -o custom-columns="POD:.metadata.name,SCHEDULER:.spec.schedulerName"
    done
}

# d) Descripción y métricas de pods del scheduler
describe_scheduler() {
    echo "=== DESCRIPCIÓN DEL SCHEDULER 'my-scheduler' ==="

    pods=$(kubectl get pods -n kube-system -l app=my-scheduler -o jsonpath='{.items[*].metadata.name}')

    if [[ -z "$pods" ]]; then
        echo "No se encontraron pods del scheduler"
        return 1
    fi

    for pod in $pods; do
        echo ""
        echo "--- Describiendo pod/$pod ---"
        kubectl describe pod "$pod" -n kube-system
    done

    echo ""
    echo "=== LOGS DEL SCHEDULER 'my-scheduler' ==="
    for pod in $pods; do
        echo ""
        echo "--- Logs de pod/$pod ---"
        kubectl logs -n kube-system "$pod"
    done

    echo ""
    echo "=== MÉTRICAS DEL SCHEDULER 'my-scheduler' ==="
    for pod in $pods; do
        echo ""
        echo "--- Métricas de pod/$pod ---"
        kubectl top pod "$pod" -n kube-system
    done
}

# e) eventos generados en aplicación delso pods en el cluster
show_pods_all_events() {
    echo "=== EVENTOS DE TODOS LOS PODS EN NAMESPACE '$NAMESPACE' ==="
    kubectl get events -n "$NAMESPACE" \
        --field-selector involvedObject.kind=Pod \
        --sort-by='.lastTimestamp'
}

# f) Creamos una función univearsal para esdperar si un objeto se ha eliminado
# Función que espera hasta que un recurso deje de existir.
# La usamos cuando necesitamos asegurarnos de que un objeto,
# proceso o elemento desaparece antes de continuar el flujo del script.
# ----------
# Esperamos hasta que algo desaparezca (contenedores, contextos, etc.).
# Recibe una descripción y un comando que indica si sigue existiendo.
# Uso:
#   wait_until_gone "contenedores del cluster" \
#       "docker ps --format '{{.Names}}' | grep -q \"^${CLUSTER_NAME}-\""
#
#   wait_until_gone "contexto Kubeconfig" \
#       "kubectl config get-contexts | grep -q \"kind-${CLUSTER_NAME}\""
wait_until_gone() {
    local description="$1"
    local check_cmd="$2"

    echo "Esperando a que desaparezca: $description"
    until ! eval "$check_cmd"; do
        sleep 1
    done
}
# g) Creamos una función para los objetos  kube
# Función que espera a que un recurso Kubernetes pase al estado Ready.
# La usamos cuando necesitamos sincronizar la ejecución con la creación
# o inicialización real de Pods, Deployments, Nodes u otros recursos.
#
# Uso:
#   wait_k8s_ready "pod" "my-pod" "my-namespace"
#   wait_k8s_ready "node" "my-nodo"
wait_k8s_ready() {
    local tipo="$1"
    local nombre="$2"
    local namespace="${3:-}" # De esta forma, si no se pasa la variable se queda como cadaena vacia. (ojo!! por set -u)

    echo "Esperando a que $tipo/$nombre esté Ready..."

    if [[ "$namespace" != "" ]]; then
        kubectl wait --for=condition=Ready "$tipo/$nombre" -n "$namespace" --timeout=120s
    else
        kubectl wait --for=condition=Ready "$tipo/$nombre" --timeout=120s
    fi
}
# h) Función para recrear nuevamente todo el cluster, preguntando limitaciones 
#    de ram y cpu. Tambi´ñen pregunta el número de workjers, el número de pods y
#    si se pretende desplegar en serie o paralelo los pods. 

# h-1) Función limpia par eliminar un cluster pasandole el nombre del clsuter a eliminar-
# Función que comprueba si un clúster existe y lo elimina limpiamente.
# La usamos para asegurar que no quedan restos de contenedores ni contextos
# antes de crear uno nuevo.
# NOTA: Esta función está específicamente diseñada para clústeres Kind.
#       Para otros entornos Kubernetes, los comandos de comprobación y eliminación
#       deberían adaptarse según corresponda. Por ejemplo:
#
#   Para MicroK8s:
#       check_cmd:  microk8s status --wait-ready >/dev/null 2>&1
#       delete_cmd: microk8s stop
#
#   Para Minikube:
#       check_cmd:  minikube status -b none | grep -q "Running"
#       delete_cmd: minikube delete
#
#   Para pods Docker:
#       check_cmd:  docker ps --format '{{.Names}}' | grep -q "^my-pod$"
#       delete_cmd: docker rm -f my-pod
#
# En general, hay que cambiar los comandos de comprobación y eliminación
# por los equivalentes según el tipo de clúster u objeto que se quiera gestionar.
# Además,se debe tener en cuenta que, por ejemplo, 'MicroK8s'  ya es un clúster único
# que corre directamente en el Host. No se puede “crear otro clúster dentro de MicroK8s”.
# Solo se  tiene una instancia de MicroK8s, que incluye todos los componentes de Kubernetes.
# En cambio, con Minikube sí se permite crear varios clústeres usando diferentes perfiles
# (minikube start -p <perfil>), por eso se tiene un concepto similar a Kind de “lista de clústeres”.
# ---123-- Revisar la codificaión porque supmgo wqeu puedo optimizarla mdoificando al lógica de control.
# A simple visrtaq, computacionalmente sería igual, pero creo que puedo cambiar el if a negación y salir
# directamente si no existe el clúster. Pero de momento dejo esto así ....

ensure_cluster_deleted() {
    local cluster="$1"

    echo "Comprobando si el cluster '$cluster' existe..."

    if kind get clusters | grep -q "^${cluster}$"; then
        echo "Clúster detectado. Procedemos a eliminarlo."
        kind delete cluster --name "$cluster"

        wait_until_gone "contenedores del cluster" \
            "docker ps --format '{{.Names}}' | grep -q \"^${cluster}-\""

        wait_until_gone "contexto Kubeconfig" \
            "kubectl config get-contexts | grep -q \"kind-${cluster}\""

        echo "El clúster se ha eliminado correctamente."
    else
        echo "El clúster '$cluster' no existe."

        local existing=$(kind get clusters | wc -l)
        if [[ "$existing" -eq 0 ]]; then
            echo "No hay ningún clúster Kind desplegado actualmente en esta máquina."
        else
            echo "Hay $existing clúster(es) disponible(s):"
            kind get clusters
        fi
    fi
}
# h-2) Función para crear un clúster Kind de forma robusta
# Recibe el nombre del clúster y el archivo de configuración
# Uso: create_kind_cluster "sched-lab" "kind-config.yaml"
# ---123-- ahora no, pero para la administración quiero hace ruan funcion 
# generica que sepa si uso kind, minicube o microk8s y sirva igual.. 
# local type="$1"        # kind | minikube | microk8s
#
create_kind_cluster() {
    local cluster="$1"
    local config_file="$2"
    local retries=3      # Número de intentos si falla la creación
    local attempt=1

    echo "Creando clúster Kind '$cluster' usando configuración '$config_file'..."

    while [[ $attempt -le $retries ]]; do
        if kind create cluster --name "$cluster" --config "$config_file"; then
            echo "Clúster '$cluster' creado correctamente."

            echo "Esperando a que el nodo principal '$cluster-control-plane' esté Ready..."
            if wait_k8s_ready "node" "$cluster-control-plane" "kube-system"; then
                echo "Nodo principal Ready. Clúster '$cluster' operativo."
                return 0
            else
                echo "ERROR: Nodo principal no pasó a Ready. Intentando de nuevo ($attempt/$retries)..."
            fi
        else
            echo "ERROR: Falló la creación del clúster '$cluster'. Intento ($attempt/$retries)..."
        fi
        ((attempt++))
        sleep 2
    done

    return 1
}

# h-3) Función: check_host_resources
# Valida que haya suficiente memoria y CPU en el host
# para crear un clúster con X workers, cada uno con cierta memoria y CPU
# Uso: check_host_resources NUM_WORKERS CPU_PER_NODE MEM_PER_NODE
# Devuelve 0 si hay recursos suficientes, 1 si no
# ========================================
# ----123-- En el pc que tengo no peudo hacer estos calculos así que sólo
# saco información al usuario sin realizar limitaciones por nodo. Sólo
# se realizarán limitaciones pod Pod en su manifiesto.
###################################
check_host_resources_default() {
    # ===============================
    # Información del host
    # ===============================
    local mem_total mem_available cpu_total

    mem_total=$(awk '/MemTotal/ {printf "%.0f MiB",$2/1024}' /proc/meminfo)
    mem_available=$(awk '/MemAvailable/ {printf "%.0f MiB",$2/1024}' /proc/meminfo)
    cpu_total=$(nproc)

    # ===============================
    # Mostrar al usuario
    # ===============================
    echo "=== Recursos del host ===" >&2
    echo "Memoria total      : $mem_total" >&2
    echo "Memoria disponible : $mem_available" >&2
    echo "CPUs disponibles   : $cpu_total" >&2
    echo "=========================" >&2
}
check_host_resources() {
    local workers="$1"
    local cpu_per_node="$2"
    local mem_per_node="$3"

    # ===============================
    # Debug a stderr
    # ===============================
    {
        echo "=== Estado actual del host ==="
        awk '/MemTotal|MemAvailable/ {printf "%s: %.0f MiB\n",$1,$2/1024}' /proc/meminfo
        echo "Núcleos disponibles: $(nproc)"
        echo "=============================="
    } >&2

    # ===============================
    # Sanitizar memoria: eliminar "i" si existe
    # ===============================
    local mem_sanitized="${mem_per_node^^}"       # a mayúsculas
    mem_sanitized="${mem_sanitized//GI/G}"       # eliminar i
    local mem_bytes_needed
    mem_bytes_needed=$(numfmt --from=iec "$mem_sanitized" 2>/dev/null)

    if [[ -z "$mem_bytes_needed" ]]; then
        echo "ERROR: No se pudo interpretar la memoria solicitada: $mem_per_node" >&2
        return 1
    fi

    # Memoria disponible en bytes
    local mem_bytes_available
    mem_bytes_available=$(awk '/MemAvailable/ {print $2*1024}' /proc/meminfo)

    # Memoria total requerida (control-plane + workers)
    local total_mem_needed=$((mem_bytes_needed * (workers + 1)))

    # Ajuste de memoria y workers si es necesario
    while [[ "$total_mem_needed" -gt "$mem_bytes_available" && "$workers" -gt 0 ]]; do
        if [[ "$mem_bytes_needed" -gt 1*1024*1024*1024 ]]; then
            mem_bytes_needed=$((mem_bytes_needed - 1*1024*1024*1024))
        else
            workers=$((workers - 1))
        fi
        total_mem_needed=$((mem_bytes_needed * (workers + 1)))
    done

    if [[ "$total_mem_needed" -gt "$mem_bytes_available" ]]; then
        echo "ERROR: No se puede ajustar el cluster a los recursos disponibles." >&2
        return 1
    fi

    # ===============================
    # Validar CPU disponible
    # ===============================
    local cpu_total_host
    cpu_total_host=$(nproc)
    local cpu_needed=$((cpu_per_node * (workers + 1)))

    while [[ "$cpu_needed" -gt "$cpu_total_host" && "$workers" -gt 0 ]]; do
        if [[ "$cpu_per_node" -gt 1 ]]; then
            cpu_per_node=$((cpu_per_node - 1))
        else
            workers=$((workers - 1))
        fi
        cpu_needed=$((cpu_per_node * (workers + 1)))
    done

    # ===============================
    # Debug final de recursos ajustados
    # ===============================
    {
        echo "=== Recursos ajustados ==="
        echo "Workers: $workers, CPU por nodo: $cpu_per_node, Memoria por nodo: $((mem_bytes_needed/1024/1024)) MiB"
        echo "=========================="
    } >&2

    # ===============================
    # Retornar valores limpios para read
    # ===============================
    echo "$workers $cpu_per_node $((mem_bytes_needed/1024/1024))MiB"

    return 0
}

# h4) Crar funcion que crea un manifiesto dinámicamente con el nñumero de workers que desea el usaurio
# Función para generar un manifiesto Kind dinámico
# Parámetros:# Carpeta donde se generarán los manifiestos temporales o de recreación
#   $1 = Nombre del cluster
#   $2 = Número de workers
#   $3 = CPU por worker (opcional, para referencia)
#   $4 = Memoria por worker (opcional, para referencia)

#(generate_kind_manifest_with_limit "$CLUSTER_NAME" "$WORKERS" "$CPU" "$MEM")"
generate_kind_manifest_with_limit() {
    local cluster="$1"
    local workers="$2"
    local cpu="${3:-2}"    # Por defecto 2 CPUs
    local mem="${4:-2Gi}"  # Por defecto 2Gi
    local timestamp
    local manifest_dir="./recreate_cluster"

    # Comrpuebo si existen recursos suficientes para crear el clster pedido
    # por el usuario.
    read workers cpu mem <<< "$(check_host_resources "$workers" "$cpu" "$mem")" || {
        echo "Abortando: recursos insuficientes." >&2
        return 1
    }


    echo "Usaremos $workers workers, $cpu CPUs, $mem memoria por nodo">&2
    # Creamos el manifiesto dinñamicamente una vez comrpobamso que si existen recursos suficientes
    timestamp=$(date +"%Y%m%d-%H%M%S")

    # Crear directorio si no existe
    mkdir -p "$manifest_dir"

    # Nombre del manifiesto con fecha
    kind_config="$manifest_dir/kind-config-${cluster}-${timestamp}.yaml"

    echo "Generando manifiesto Kind dinámico en: $kind_config" >&2

    # Crear YAML base
    cat > "$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

    # Añadir los workers
    for ((i=1;i<=workers;i++)); do
        cat >> "$kind_config" <<EOF
  - role: worker
     # CPU=${cpu}, MEM=${mem} (referencia)
EOF
    done

    # Comprobar que el archivo se creó correctamente
    if [[ ! -f "$kind_config" ]]; then
        echo "ERROR: No se pudo crear el manifiesto en $KIND_CONFIG" >&2
        return 1
    fi

    echo "Manifiesto generado [$kind_config] con: $workers workers, CPU=$cpu, MEM=$mem (solo referencia en YAML)"  >&2

    # **Devolver el nombre del archivo**
    echo "$kind_config $workers $cpu $mem"
    return 0

}
generate_kind_manifest_default_workers() {
    local cluster="$1"
    local workers="$2"
    local timestamp
    local manifest_dir="./recreate_cluster"

    # Comrpuebo si existen recursos suficientes para crear el cluster pedido
    # por el usuario.
    check_host_resources_default

    # Creamos el manifiesto dinñamicamente una vez comrpobamso que si existen recursos suficientes
    timestamp=$(date +"%Y%m%d-%H%M%S")

    # Crear directorio si no existe
    mkdir -p "$manifest_dir"

    # Nombre del manifiesto con fecha
    kind_config="$manifest_dir/kind-config-${cluster}-${timestamp}.yaml"

    echo "Generando manifiesto Kind dinámico en: $kind_config" >&2

    # Crear YAML base
    cat > "$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

    # Añadir los workers
    for ((i=1;i<=workers;i++)); do
        cat >> "$kind_config" <<EOF
  - role: worker
EOF
    done

    # Comprobar que el archivo se creó correctamente
    if [[ ! -f "$kind_config" ]]; then
        echo "ERROR: No se pudo crear el manifiesto en $KIND_CONFIG" >&2
        return 1
    fi

    echo "Manifiesto generado [$kind_config] con: $workers workers"  >&2

    # **Devolver el nombre del archivo**
    echo "$kind_config"
    return 0

}
# h-5) Limitar recursos físicos solo de los nodos worker de un clúster Kind
# ========================================
# $1 = nombre del clúster
# $2 = CPUs por worker
# $3 = Memoria por worker (ej: 2Gi)
#
# ---123-- Nota: esto es una limitación basica. Pero hayq ue tener en cuenta que es en los manifiestos
# de los pods donde se limita la memoria y cpu que peude concumir 
#
#resources:
#  requests:
#    memory: "512Mi"
#    cpu: "0.5"
#  limits:
#    memory: "1Gi"
#    cpu: "1"
#
#  Además, al menos en kind, no hay forma de redistribuir la memoria y cpu que tiene el Host entre los 
# nodos ya creados dentro del clúster. LA limitación se hace con Docker update, ya que son contenedores
# Docker. Pero, al menos yo no he encotrado una forma que en caleinte pueda redistribuir y añadir o  quitar
# cpuo memoria (Sobre todo memoria) según la carga de trabajo del nodo o la predicción de su carga ---123-- 
# preguntar al profesor....

limit_worker_resources() {
    local cluster="$1"
    local cpu="$2"
    local mem="$3"

    # Convertir memoria a bytes para docker (ej: 2Gi -> 2147483648)
    local mem_bytes
    mem_clean=$(echo "$mem" | sed 's/MiB/Mi/I' | sed 's/GiB/Gi/I')
    mem_bytes=$(numfmt --from=iec "$mem_clean" 2>/dev/null)
    if [[ -z "$mem_bytes" ]]; then
        echo "ERROR: No se pudo convertir la memoria '$mem'."
        return 1
    fi

    # Obtener lista de contenedores Docker que sean workers
    local worker_nodes
    worker_nodes=$(docker ps --format '{{.Names}}' | grep "^${cluster}-worker")
    if [[ -z "$worker_nodes" ]]; then
        echo "No se encontraron nodos worker para el clúster '$cluster'."
        return 1
    fi

    echo "Limitando recursos de los nodos worker del clúster '$cluster': CPU=$cpu, MEM=$mem"

    for node in $worker_nodes; do
        # Ajustamos memoria y memory-swap al mismo tiempo
        if docker update --cpus="$cpu" --memory="$mem_bytes" --memory-swap="$mem_bytes" "$node"; then
            echo "Nodo worker $node limitado correctamente."
        else
            echo "WARNING: No se pudo limitar los recursos de $node."
        fi
    done

    echo "Recursos limitados para todos los workers del clúster '$cluster'."
    return 0
}

# h-6) LA fucnión que realmete recrea el clúster 
recreate_kind_cluster_default() {
    # Pedir datos al usuario con valores por defecto
    read -p "Nombre del cluster [sched-lab]: " CLUSTER_NAME
    CLUSTER_NAME=${CLUSTER_NAME:-sched-lab}

    read -p "Número de workers [2] (1-$DEFAULT_WORKERS): " WORKERS
    WORKERS=${WORKERS:-2}
    if ! [[ "$WORKERS" =~ ^[1-$DEFAULT_WORKERS]$ ]]; then
        echo "Número inválido, usando valor por defecto 2."
        WORKERS=2
    fi

    echo "Recreando cluster $CLUSTER_NAME con $WORKERS workers..."

    # Eliminar cluster si existe
    ensure_cluster_deleted "$CLUSTER_NAME"

    # Generar el manifiesto y capturar el nombre del archivo
    read config_file <<< "$(generate_kind_manifest_default_workers "$CLUSTER_NAME" "$WORKERS")" || {
        echo "Fallo al generar manifiesto. Abortando." >&2
        exit 1
    }

    # Informar al usuario
    echo "Manifiesto listo: $config_file" >&2
    echo "Workers ajustados: $WORKERS" >&2

    # Crear el cluster usando la función create_kind_cluster
    if create_kind_cluster "$CLUSTER_NAME" "$config_file"; then
        echo "Clúster '$CLUSTER_NAME' recreado y listo para usar." >&2
    else
        echo "ERROR: No se pudo recrear el clúster '$CLUSTER_NAME'." >&2
        return 1
    fi

    echo "Cluster recreado." >&2

    # CONFIGURAR ETIQUETAS Y TAINTS DESPUÉS DE CREAR EL CLUSTER
    configure_node_labels_and_taints "$CLUSTER_NAME"

    # Crear namespace y lanzar scheduler automáticamente
    kubectl create ns "$NAMESPACE"
    create_scheduler_custom
    load_image_in_cluster

    echo "Cluster configurado." >&2

    # Instalar servidor de métricas
    install_metrics_server
    echo "Namespace '$NAMESPACE' y scheduler 'my-scheduler' aplicados." >&2

    # Preguntar si quiere lanzar pods de prueba
    read -p "¿Deseas lanzar pods de prueba? (s/n) [n]: " LANZAR_PODS
    LANZAR_PODS=${LANZAR_PODS:-n}

    if [[ "$LANZAR_PODS" == "s" ]]; then
        create_pods_from_yaml
        echo "Esperando a que los pods de prueba estén en estado Running..." >&2
        #kubectl wait --for=condition=Ready pod -n "$NAMESPACE" --all --timeout=120s
        echo "Esperando a que los pods de prueba estén completados..."

        kubectl wait --for=condition=ready pod -n "$NAMESPACE" --all --timeout=120s

        echo "Pods de prueba lanzados y listos. Estado actual por nodo:" >&2
        show_pods_by_node_with_scheduler
    fi
}

# Con limitacione
# Lo intenté , pero en mi PC me da problemas de memoria
recreate_kind_cluster_with_limits() {
    # Pedir datos al usuario con valores por defecto
    read -p "Nombre del cluster [sched-lab]: " CLUSTER_NAME
    CLUSTER_NAME=${CLUSTER_NAME:-sched-lab}

    read -p "Número de workers [2] (1-$DEFAULT_WORKERS): " WORKERS
    WORKERS=${WORKERS:-2}
    if ! [[ "$WORKERS" =~ ^[1-$DEFAULT_WORKERS]$ ]]; then
        echo "Número inválido, usando valor por defecto 2."
        WORKERS=2
    fi

    read -p "CPU por worker (ej: 2) [2]: " CPU
    CPU=${CPU:-2}

    read -p "Memoria por worker (ej: 2Gi) [2Gi]: " MEM
    MEM=${MEM:-2Gi}

     Asegurarse de que la memoria tenga unidad
    if [[ ! "$MEM" =~ [0-9]+(Gi|G|Mi|M)$ ]]; then
        echo "No se detectó unidad en la memoria, añadiendo Gi por defecto."
        MEM="${MEM}Gi"
    fi

    echo "Recreando cluster $CLUSTER_NAME con $WORKERS workers, CPU=$CPU, MEM=$MEM por worker..."

    # Eliminar cluster si existe.
    ensure_cluster_deleted "$CLUSTER_NAME"

    # Generar el manifiesto y capturar valores
    if ! output=$(generate_kind_manifest_with_limit "$CLUSTER_NAME" "$WORKERS" "$CPU" "$MEM"); then
        echo "Fallo al generar manifiesto. Abortando." >&2
        exit 1
    fi

    # Suponemos que la función imprime en la última línea: config_file workers cpu mem
    # Extraemos la última línea y leemos los valores en variables
    read -r config_file workers cpu mem <<< "$(echo "$output" | tail -n1)"

    # Comprobamos que config_file no esté vacío
    if [[ -z "$config_file" ]]; then
        echo "ERROR: No se pudo obtener el path del manifiesto." >&2
        return 1
    fi

    # Informar al usuario
    echo "Manifiesto listo: $config_file" >&2
    echo "Workers ajustados: $workers" >&2
    echo "CPU ajustada: $cpu" >&2
    echo "MEM ajustada: $mem" >&2

    # Crear el cluster usando la función robuconfig_filesta
    if create_kind_cluster "$CLUSTER_NAME" "$config_file"; then
        echo "Clúster '$CLUSTER_NAME' recreado y listo para usar.">&2
    else
        echo "ERROR: No se pudo recrear el clúster '$CLUSTER_NAME'.">&2
        return 1
    fi

    # CONFIGURAR ETIQUETAS Y TAINTS DESPUÉS DE CREAR EL CLUSTER
    configure_node_labels_and_taints "$CLUSTER_NAME"

    limit_worker_resources "$CLUSTER_NAME" "$cpu" "$mem"

    echo "Cluster recreado.">&2

    # Crear namespace y lanzar scheduler automáticamente
    kubectl create ns "$NAMESPACE"

    create_scheduler_custom
    load_image_in_cluster

    echo "Cluster recreado.">&2

    #Se instala el servidor de métricas
    install_metrics_server
    echo "Namespace '$NAMESPACE' y scheduler 'my-scheduler' aplicados.">&2

    # Preguntar si quiere lanzar pods de prueba
    read -p "¿Deseas lanzar pods de prueba? (s/n) [n]: " LANZAR_PODS
    LANZAR_PODS=${LANZAR_PODS:-n}

    if [[ "$LANZAR_PODS" == "s" ]]; then
        create_pods_from_yaml

        echo "Esperando a que los pods de prueba estén en estado Running...">&2
        # Esperar a que todos los pods del namespace estén listos
        kubectl wait --for=condition=Ready pod -n "$NAMESPACE" --all --timeout=120s

        echo "Pods de prueba lanzados y listos. Estado actual por nodo:">&2
        show_pods_by_node_with_scheduler
    fi
}
# i) Borrar el contenido de namespace (test-scheduler) donde creo los pdos
cleanup_namespace() {
    local ns="$1"
    if [[ -z "$ns" ]]; then
        echo "ERROR: No se proporcionó el namespace"
        return 1
    fi

    echo "=== LIMPIANDO TODOS LOS RECURSOS EN NAMESPACE '$ns' ==="

    local resources=("pods" "services" "deployments" "replicasets" "configmaps" "secrets" "jobs" "cronjobs" "statefulsets" "daemonsets")

    for resource in "${resources[@]}"; do
        echo "Eliminando $resource..."
        kubectl delete "$resource" --all -n "$ns" --ignore-not-found=true --wait=false 2>/dev/null || true
    done

    echo "✅ Comando de limpieza enviado. Algunos recursos pueden tardar unos segundos en eliminarse."
}

create_pods_and_scheduler() {
    echo ">>> Creando recursos de prueba..."

    # Crear el namespace si no existe
    kubectl create ns "$NAMESPACE" 2>/dev/null || echo "Namespace ya existe"

   # Volver a lanzar tu my-scheduler
   create_scheduler_custom

   # Crear los Pods
   create_pods_from_yaml
}


# Hemos implementado una política de distribución en la creación de pods mediante un algoritmo round-robin 
# que intercala los tipos de pods. Esto lo hacemos para evitar que se creen muchos pods del mismo tipo consecutivamente, 
# lo que podría llevar a una distribución desigual en los nodos si el scheduler no tiene en cuenta la diversidad 
# de recursos.
# --123-- Esto hay que implementarlo dentro de scheduler.py porque el scheduler puede, segun la carga, asignar al mismo nodo 
# pods del mismo tipo. PEro se tendría la mísma filosofía.

load_pods_from_yaml() {
    local -n DIRS=$1
    local total_pods=$2
    local mode=${3:-s}
    local parallel=${4:-1}

    local counter=0 batch pod_yaml

    echo "Creando $total_pods pods desde YAML ($mode, $parallel en paralelo)..."

    while [[ $counter -lt $total_pods ]]; do
        batch=$(( total_pods - counter < parallel ? total_pods - counter : parallel ))

        for ((i=1;i<=batch;i++)); do
            dir_index=$(( (counter + i - 1) % ${#DIRS[@]} ))
            pod_yaml="${DIRS[$dir_index]}/${DIRS[$dir_index]}-pod.yaml"

            if [[ ! -f "$pod_yaml" ]]; then
                warn "Archivo $pod_yaml no existe, se omite"
                continue
            fi
            pids=()
            if grep -q 'generateName:' "$pod_yaml"; then
                info "Creando pod desde $pod_yaml con generateName..."
                if [[ "$mode" == "p" ]]; then
                    kubectl create -f "$pod_yaml" &
                    pids+=($!)
                else
                    kubectl create -f "$pod_yaml"
                fi
            else
                info "Creando pod desde $pod_yaml con nombre fijo..."
                if [[ "$mode" == "p" ]]; then
                    kubectl apply -f "$pod_yaml" &
                    pids+=($!)
                else
                    kubectl apply -f "$pod_yaml"
                fi
            fi
        done

        [[ "$mode" == "p" ]] && wait "${pids[@]}"
        counter=$((counter + batch))
    done

    echo "Todos los pods creados desde YAML."
}


create_pods_from_yaml() {
    local dirs_array=("cpu-heavy" "ram-heavy" "nginx" "test-basic")
    local total_pods parallel mode

    # Pedir número total de pods con límite
    read -p "Número total de pods a crear (1-$MAX_TOTAL_PODS) [${MAX_TOTAL_PODS}]: " total_pods
    total_pods=${total_pods:-$MAX_TOTAL_PODS}

    while ! [[ "$total_pods" =~ ^[0-9]+$ && "$total_pods" -ge 1 && "$total_pods" -le $MAX_TOTAL_PODS ]]; do
        echo "Debe ser un número entero positivo entre 1 y $MAX_TOTAL_PODS"
        read -p "Número total de pods a crear (1-$MAX_TOTAL_PODS): " total_pods
    done

    read -p "Modo de lanzamiento (s=secuencial, p=paralelo) [s]: " mode
    mode=${mode:-s}
    while [[ ! "$mode" =~ ^[sp]$ ]]; do
        echo "Elige s para secuencial o p para paralelo"
        read -p "Modo de lanzamiento: " mode
    done

    # Número de pods en paralelo
    if [[ "$mode" == "p" ]]; then
        read -p "Número de pods a lanzar en paralelo (1-$MAX_PARALLEL_PODS) [${MAX_PARALLEL_PODS}]: " parallel
        parallel=${parallel:-$MAX_PARALLEL_PODS}

        while ! [[ "$parallel" =~ ^[0-9]+$ && "$parallel" -ge 1 && "$parallel" -le $MAX_PARALLEL_PODS ]]; do
            echo "Debe ser un número entero entre 1 y $MAX_PARALLEL_PODS"
            read -p "Número de pods a lanzar en paralelo (1-$MAX_PARALLEL_PODS): " parallel
        done
    else
        parallel=1
    fi
    echo "Creando $total_pods pods desde YAML ($mode, $parallel en paralelo)..."

    # PASAMOS EL ARRAY POR REFERENCIA Y LOS VALORES
    load_pods_from_yaml dirs_array "$total_pods" "$mode" "$parallel"

    echo "Todos los pods creados desde YAML."
}
create_pods() {

    # Pedir número total de pods con límite
    read -p "Número total de pods a crear (1-$MAX_TOTAL_PODS) [${MAX_TOTAL_PODS}]: " total_pods
    total_pods=${total_pods:-$MAX_TOTAL_PODS}

    while ! [[ "$total_pods" =~ ^[0-9]+$ && "$total_pods" -ge 1 && "$total_pods" -le $MAX_TOTAL_PODS ]]; do
        echo "Debe ser un número entero positivo entre 1 y $MAX_TOTAL_PODS"
        read -p "Número total de pods a crear (1-$MAX_TOTAL_PODS): " total_pods
    done

    read -p "Modo de lanzamiento (s=secuencial, p=paralelo): " modo
    while [[ ! "$modo" =~ ^[sp]$ ]]; do
        echo "Elige s para secuencial o p para paralelo"
        read -p "Modo de lanzamiento: " modo
    done

    # Número de pods en paralelo
    if [[ "$mode" == "p" ]]; then
        read -p "Número de pods a lanzar en paralelo (1-$MAX_PARALLEL_PODS) [${MAX_PARALLEL_PODS}]: " parallel
        parallel=${parallel:-$MAX_PARALLEL_PODS}

        while ! [[ "$parallel" =~ ^[0-9]+$ && "$parallel" -ge 1 && "$parallel" -le $MAX_PARALLEL_PODS ]]; do
            echo "Debe ser un número entero entre 1 y $MAX_PARALLEL_PODS"
            read -p "Número de pods a lanzar en paralelo (1-$MAX_PARALLEL_PODS): " parallel
        done
    else
        parallel=1
    fi
    echo "Creando $total pods ($modo, $paralelo en paralelo)..."

    contador=0
    while [[ $contador -lt $total ]]; do
        batch=$(( total - contador < paralelo ? total - contador : paralelo ))
        for ((i=1;i<=batch;i++)); do
            pod_name="test-pod-$((contador+i))"
            kubectl run "$pod_name" --image=busybox --restart=Never -- sleep 3600 &
        done
        wait  # Espera a que termine el batch
        contador=$((contador + batch))
    done

    echo "Todos los pods creados."
}


check_dependencies() {
    command -v kubectl >/dev/null 2>&1 || error "kubectl no encontrado"
    command -v kind >/dev/null 2>&1 || error "kind no encontrado"
    command -v docker >/dev/null 2>&1 || error "docker no encontrado"
}


#cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
#kind: Cluster
#apiVersion: kind.x-k8s.io/v1alpha4
#nodes:
#- role: control-plane
#- role: worker
#- role: worker
#EOF


create_cluster() {
    if ! kind get clusters | grep -q "$CLUSTER_NAME"; then
        info "Creando cluster Kind: $CLUSTER_NAME"
        kind create cluster --name "$CLUSTER_NAME" --config kind-cluster.yaml
        info "Cluster creado exitosamente"
    else
        info "Cluster $CLUSTER_NAME ya existe"
    fi
}

create_namespace() {
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        info "Creando namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    else
        info "Namespace $NAMESPACE ya existe"
    fi
}
create_scheduler_custom() {
    local scheduler_ns="kube-system"
    local cluster_name="sched-lab"
    local node_cp="${cluster_name}-control-plane"
    info "Aplicando scheduler personalizado en namespace '$scheduler_ns'"

    # Construir la imagen Docker localmente
    docker build -t my-py-scheduler:latest .

    # Cargar la imagen solo en el nodo control-plane
    info "Cargando la imagen solo en el nodo control-plane ($node_cp)"
    kind load docker-image my-py-scheduler:latest --name "$cluster_name" --nodes "$node_cp"

    # Comprobamos que la imagen está en el control plane
    docker exec -it "$node_cp" crictl images | grep my-py-scheduler || warn "Imagen no encontrada en control plane"

    info "Aplicando scheduler personalizado en namespace '$scheduler_ns'"

    sleep 2

    # Validar YAML primero (opcional)
    if ! kubectl apply --dry-run=client -f rbac-deploy.yaml -n "$scheduler_ns" >/dev/null 2>&1; then
        error "YAML del scheduler contiene errores o es incompatible con el cluster"
    fi

    # Aplicar realmente el scheduler
    if ! kubectl apply -f rbac-deploy.yaml -n "$scheduler_ns" >/dev/null 2>&1; then
        error "No se pudo aplicar el scheduler desde rbac-deploy.yaml"
    fi

    info "Scheduler aplicado. Esperando a que el Pod del scheduler esté listo..."

    # Esperar a que el scheduler esté Running
    local timeout=60  # segundos
    local elapsed=0
    local interval=2

    while true; do
        local pod phase
        pod=$(kubectl get pods -n "$scheduler_ns" -l app=my-scheduler -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$pod" ]]; then
            phase=$(kubectl get pod "$pod" -n "$scheduler_ns" -o jsonpath='{.status.phase}' 2>/dev/null)
            if [[ "$phase" == "Running" ]]; then
                info "Scheduler personalizado está activo y en Running"
                break
            fi
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        if [ $elapsed -ge $timeout ]; then
            warn "Tiempo de espera excedido: el scheduler aún no está listo"
            break
        fi
    done
    
    # Verificar configuración después de que esté running
    verify_scheduler_configuration
}

cleanup_old_pods() {
    info "Limpiando pods anteriores en namespace $NAMESPACE"
    kubectl delete pods --all -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force 2>/dev/null || true

    # Esperar a que desaparezcan
    while [[ $(kubectl get pods -n "$NAMESPACE" -o name | wc -l) -gt 0 ]]; do
        sleep 1
    done

    info "Todos los pods anteriores eliminados"
}
# ========================================
# FUNCIONES DE CREACIÓN Y MONITOREO DE PODS
# ========================================

create_single_pod() {
    local pod_name=$1
    local attempt=0
    local max_attempts=3

    while [ $attempt -lt $max_attempts ]; do
        info "Creando pod: $pod_name (intento $((attempt + 1)))"

if kubectl apply -n "$NAMESPACE" -f - >/dev/null 2>&1 <<EOF; then
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  labels:
    app: test-pod
    test-id: "$pod_name"
spec:
  containers:
  - name: main-container
    image: $POD_IMAGE
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
        cpu: "100m"
  restartPolicy: Never
EOF

            # Esperar a que el pod sea reconocido por la API
            local wait_attempt=0
            while [ $wait_attempt -lt 10 ]; do
                if kubectl get pod "$pod_name" -n "$NAMESPACE" >/dev/null 2>&1; then
                    debug "Pod $pod_name creado exitosamente"
                    return 0
                fi
                sleep 1
                ((wait_attempt++))
            done
        fi

        attempt=$((attempt + 1))
        debug "Intento $attempt fallado para $pod_name, reintentando..."
        sleep 2
    done

    error "No se pudo crear el pod $pod_name después de $max_attempts intentos"
}

monitor_pod() {
    local pod_name=$1
    local timeout=120
    local counter=0

    info "Monitoreando pod: $pod_name"
    while [ $counter -lt $timeout ]; do
        local phase
        phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        case $phase in
            "Running")
                info "✅ POD $pod_name ESTÁ RUNNING"
                return 0
                ;;
            "Succeeded")
                info "ℹ️  POD $pod_name COMPLETADO (Succeeded)"
                return 0
                ;;
            "Failed")
                local reason
                reason=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || echo "Unknown")
                info "❌ POD $pod_name FALLADO: $reason"
                return 1
                ;;
            "Pending")
                debug "Pod $pod_name pendiente... ($counter/$timeout)"
                ;;
            "Unknown")
                debug "Pod $pod_name estado desconocido..."
                ;;
        esac
        sleep 2
        counter=$((counter + 2))
    done
    info "⏰ TIMEOUT esperando por pod $pod_name"
    echo "=== DETALLES DEL POD $pod_name ==="
    kubectl describe pod "$pod_name" -n "$NAMESPACE" 2>/dev/null || echo "No se puede describir el pod"
    echo "=== LOGS DEL POD $pod_name ==="
    kubectl logs "$pod_name" -n "$NAMESPACE" --tail=20 2>/dev/null || echo "No se pudieron obtener logs"
    return 1
}

create_pods_parallel() {
    info "Iniciando creación de $TOTAL_PODS pods con $MAX_CONCURRENT_PODS concurrentes"
    local completed=0
    local failed=0
    declare -a all_pods=()
    declare -A pod_results

    # Generar nombres de pods
    for i in $(seq 1 "$TOTAL_PODS"); do
        all_pods+=("test-pod-$i")
        pod_results["test-pod-$i"]="pending"
    done

    local i=0
    while [ $i -lt ${#all_pods[@]} ]; do
        local remaining_pods=$((${#all_pods[@]} - i))
        local batch_size=$(( remaining_pods < MAX_CONCURRENT_PODS ? remaining_pods : MAX_CONCURRENT_PODS ))

        local batch=()
        for ((j=0; j<batch_size; j++)); do
            batch+=("${all_pods[i+j]}")
        done

        info "Procesando lote de ${#batch[@]} pods ($((i+1))-$((i+${#batch[@]})) de $TOTAL_PODS)"

        # Crear todos los pods del lote primero
        local create_pids=()
        for pod_name in "${batch[@]}"; do
            info "Creando pod: $pod_name"
            create_single_pod "$pod_name" &
            create_pids+=($!)
        done

        # Esperar a que todos los pods se creen
        info "Esperando a que se creen ${#create_pids[@]} pods..."
        for pid in "${create_pids[@]}"; do
            if wait "$pid"; then
                debug "Pod creado exitosamente"
            else
                warn "Error creando pod"
                ((failed++))
            fi
        done

        # Monitorear pods secuencialmente en este lote
        info "Monitoreando pods del lote actual..."
        for pod_name in "${batch[@]}"; do
            echo " Comprobar --> $pod_name"
            if monitor_pod "$pod_name"; then
                pod_results["$pod_name"]="success"
                ((completed++))
                info "✅ Pod $pod_name completado exitosamente"
            else
                pod_results["$pod_name"]="failed"
                ((failed++))
                warn "❌ Pod $pod_name falló"
            fi
        done

        info "Progreso: $completed completados, $failed fallados de $TOTAL_PODS totales"
        
        # Avanzar al siguiente lote
        i=$((i + batch_size))
        
        # Pequeña pausa entre lotes
        if [ $i -lt ${#all_pods[@]} ]; then
            info "Preparando siguiente lote..."
            sleep 2
        fi
    done

    # Resumen final
    info "=== RESUMEN FINAL ==="
    info "Pods completados exitosamente: $completed"
    info "Pods fallados: $failed"
    info "Total procesado: $((completed + failed))"

    echo "=== ESTADO FINAL DE TODOS LOS PODS ==="
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "No hay pods para mostrar"

    return $failed
}
create_pods_parallel_from_yaml() {
    info "Iniciando creación de $TOTAL_PODS pods con $MAX_CONCURRENT_PODS concurrentes desde YAML"
    local completed=0
    local failed=0
    declare -A pod_results
    declare -A pid_to_file

    local DIRS=("cpu-heavy" "ram-heavy" "nginx" "test-basic")
    local i=0

    while [ $i -lt $TOTAL_PODS ]; do
        local remaining=$(( TOTAL_PODS - i ))
        local batch_size=$(( remaining < MAX_CONCURRENT_PODS ? remaining : MAX_CONCURRENT_PODS ))
        local create_pids=()

        for ((j=0; j<batch_size; j++)); do
            local dir_index=$(( (i + j) % ${#DIRS[@]} ))
            local pod_yaml="${DIRS[$dir_index]}/${DIRS[$dir_index]}-pod.yaml"

            if [[ ! -f "$pod_yaml" ]]; then
                warn "Archivo $pod_yaml no existe, se omite"
                continue
            fi

            local tmpfile="/tmp/pod-$i-$j.txt"

            (
                pod_name=$(kubectl create -f "$pod_yaml" -o name | cut -d'/' -f2)
                echo "$pod_name" > "$tmpfile"
            ) &
            pid=$!
            create_pids+=($pid)
            pid_to_file[$pid]="$tmpfile"
        done

        # Esperar a que terminen los subshells y leer nombres reales
        for pid in "${create_pids[@]}"; do
            if wait "$pid"; then
                tmpfile="${pid_to_file[$pid]}"
                if [[ -s "$tmpfile" ]]; then
                    pod_name=$(<"$tmpfile")
                    debug "Pod $pod_name creado exitosamente"
                    pod_results["$pod_name"]="pending"
                else
                    warn "Error creando pod"
                    ((failed++))
                fi
                rm -f "$tmpfile"
            else
                warn "Error en el subshell de creación del pod (PID $pid)"
                ((failed++))
            fi
        done

        # Monitorear los pods creados en este lote
        for pod_name in "${!pod_results[@]}"; do
            if [[ "${pod_results[$pod_name]}" == "pending" ]]; then
                if monitor_pod "$pod_name"; then
                    pod_results["$pod_name"]="success"
                    ((completed++))
                    info "✅ Pod $pod_name completado exitosamente"
                else
                    pod_results["$pod_name"]="failed"
                    ((failed++))
                    warn "❌ Pod $pod_name falló"
                fi
            fi
        done

        i=$((i + batch_size))
        [[ $i -lt $TOTAL_PODS ]] && sleep 2
    done

    info "=== RESUMEN ==="
    info "Completados: $completed, Fallados: $failed"
}

install_metrics_server() {
    METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml"
    METRICS_IMAGE="registry.k8s.io/metrics-server/metrics-server:v0.6.3"

    log "INFO" "Comprobando si Metrics Server ya está instalado"
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        log "INFO" "Descargando imagen Metrics Server localmente"
        safe_run "Descargar imagen metrics-server" docker pull "$METRICS_IMAGE"

        log "INFO" "Cargando imagen Metrics Server en todos los nodos Kind"
        safe_run "Cargar metrics-server en todos los nodos" kind load docker-image "$METRICS_IMAGE" --name "$CLUSTER_NAME"

        log "INFO" "Aplicando manifiesto Metrics Server"
        safe_run "Aplicar metrics-server" kubectl apply -f "$METRICS_SERVER_URL"

        log "INFO" "Parcheando TLS inseguro"
        safe_run "Parchear metrics-server" kubectl patch deployment metrics-server -n kube-system --type='json' \
            -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

        log "INFO" "Esperando Metrics Server disponible (timeout 120s)"
        safe_run "Esperar metrics-server" kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system
    else
        log "INFO" "Metrics Server ya está instalado"
    fi

    log "INFO" "Pausa de 10 segundos para estabilizar"
    sleep 10

    return 0
}

delete_cluster_if_exists() {
    local cluster_name="$1"

    if kind get clusters | grep -q "^${cluster_name}$"; then
        echo "[INFO] El cluster '$cluster_name' ya existe. Eliminando..."
        kind delete cluster --name "$cluster_name"
        echo "[INFO] Cluster '$cluster_name' eliminado."
    else
        echo "[INFO] No se encontró el cluster '$cluster_name'. Continuando..."
    fi
}
configure_node_labels_and_taints() {
    local cluster_name="$1"
    info "Configurando etiquetas y taints en los nodos del cluster '$cluster_name'"
    
    # Obtener lista de nodos
    local nodes
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [[ -z "$nodes" ]]; then
        error "No se pudieron obtener los nodos del cluster"
        return 1
    fi
    
    info "Nodos encontrados: $nodes"
    
    # Aplicar etiqueta env=prod a todos los nodos
    for node in $nodes; do
        info "Aplicando etiqueta env=prod al nodo: $node"
        kubectl label node "$node" env=prod --overwrite
    done
    
    # Buscar el worker3 específicamente para aplicar el taint
    local worker3_node=""
    for node in $nodes; do
        if [[ "$node" == *"worker3"* ]] || [[ "$node" == *"worker-3"* ]]; then
            worker3_node="$node"
            break
        fi
    done
    
    # Si no encontramos worker3, buscar el último worker
    if [[ -z "$worker3_node" ]]; then
        local worker_nodes=()
        for node in $nodes; do
            if [[ "$node" == *"worker"* ]] && [[ "$node" != *"control-plane"* ]]; then
                worker_nodes+=("$node")
            fi
        done
        
        if [[ ${#worker_nodes[@]} -ge 3 ]]; then
            worker3_node="${worker_nodes[2]}"
        elif [[ ${#worker_nodes[@]} -gt 0 ]]; then
            # Si hay menos de 3 workers, usar el último worker
            worker3_node="${worker_nodes[-1]}"
        fi
    fi
    
    # Aplicar taint al worker3 si se encontró
    if [[ -n "$worker3_node" ]]; then
        info "Aplicando taint al nodo: $worker3_node"
        kubectl taint nodes "$worker3_node" example=true:NoSchedule --overwrite
    else
        warn "No se pudo encontrar un nodo worker3 para aplicar el taint"
    fi
    
    # Mostrar estado final
    info "=== ESTADO FINAL DE NODOS ==="
    kubectl get nodes -o custom-columns="NAME:.metadata.name,ENV:.metadata.labels.env,TAINTS:.spec.taints" 2>/dev/null || \
    kubectl get nodes -o wide
    
    return 0
}
verify_scheduler_configuration() {
    info "Verificando configuración del scheduler personalizado"
    
    # Verificar que el scheduler esté ejecutándose
    local scheduler_pod
    scheduler_pod=$(kubectl get pods -n kube-system -l app=my-scheduler -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$scheduler_pod" ]]; then
        error "No se encontró el pod del scheduler personalizado"
        return 1
    fi
    
    info "Scheduler pod: $scheduler_pod"
    
    # Verificar logs del scheduler para ver si está funcionando correctamente
    info "Verificando logs del scheduler..."
    kubectl logs -n kube-system "$scheduler_pod" --tail=10 | grep -i "filter\|score\|node" || true
    
    return 0
}

# ========================================
# FUNCIONES DE INTERFAZ DE USUARIO
# ========================================

show_usage() {
    echo "Uso: $0 [PODS_CONCURRENTES] [TOTAL_PODS]"
    echo "  PODS_CONCURRENTES: Número máximo de pods a crear en paralelo (default: 3)"
    echo "  TOTAL_PODS: Número total de pods a crear (default: 10)"
    echo ""
    echo "Ejemplos:"
    echo "  $0           # 3 concurrentes, 10 pods total"
    echo "  $0 5 20      # 5 concurrentes, 20 pods total"
    echo "  $0 1 5       # 1 concurrente, 5 pods total (secuencial)"
}

show_banner() {
    echo "=================================================="
    echo "  SCRIPT AVANZADO PARA PRUEBAS DE PODS K8S"
    echo "=================================================="
    echo "Cluster:      $CLUSTER_NAME"
    echo "Namespace:    $NAMESPACE"
    echo "Concurrentes: $MAX_CONCURRENT_PODS"
    echo "Total Pods:   $TOTAL_PODS"
    echo "Imagen:       $POD_IMAGE"
    echo "=================================================="
    echo ""
    echo "-------------------------------------------"
    echo "  ./start.sh <WORKERS> <TOTAL_PODS> <MAX_CONCURRENT_PODS>"
    echo "-------------------------------------------"
}

# ========================================
# EJECUCIÓN PRINCIPAL CORREGIDA
# ========================================
#------------------------------------
# Función para mostrar ayuda
show_help() {
    echo "Uso: $0 [WORKERS] [TOTAL_PODS] [MAX_CONCURRENT_PODS]"
    echo
    echo "Parámetros opcionales:"
    echo "  WORKERS               Número de workers del cluster (1-$DEFAULT_WORKERS, por defecto $DEFAULT_WORKERS)"
    echo "  TOTAL_PODS            Número total de pods a crear (1-$MAX_TOTAL_PODS, por defecto $MAX_TOTAL_PODS)"
    echo "  MAX_CONCURRENT_PODS   Número máximo de pods a lanzar en paralelo (1-$MAX_PARALLEL_PODS, por defecto $MAX_PARALLEL_PODS)"
    echo
    echo "Si quieres aumentar los límites de pods o workers, modifica las variables al inicio del script:"
    echo "  DEFAULT_WORKERS, MAX_TOTAL_PODS, MAX_PARALLEL_PODS"
    echo
    exit 0
}

#------------------------------------
# Función para mostrar info sobre límites
show_limits_info() {
    echo "-------------------------------------------"
    echo "Información de límites actuales:"
    echo "  Workers máximo permitido: $DEFAULT_WORKERS"
    echo "  Total máximo de pods: $MAX_TOTAL_PODS"
    echo "  Máximo de pods en paralelo: $MAX_PARALLEL_PODS"
    echo "Para aumentar estos valores, edita las variables al inicio del script."
    echo "-------------------------------------------"
}

#------------------------------------
# Función para validar argumentos de entrada
validate_args() {
    # Validar WORKERS
    if ! [[ "$WORKERS" =~ ^[0-9]+$ ]]; then
        echo "WORKERS no es un número, se ajusta a $DEFAULT_WORKERS"
        WORKERS=$DEFAULT_WORKERS
    fi
    if [ "$WORKERS" -lt 1 ] || [ "$WORKERS" -gt "$DEFAULT_WORKERS" ]; then
        echo "WORKERS fuera de rango, se ajusta a $DEFAULT_WORKERS"
        WORKERS=$DEFAULT_WORKERS
    fi

    # Validar TOTAL_PODS
    if ! [[ "$TOTAL_PODS" =~ ^[0-9]+$ ]] || [ "$TOTAL_PODS" -lt 1 ]; then
        echo "TOTAL_PODS inválido ($TOTAL_PODS), se ajusta a $MAX_TOTAL_PODS"
        TOTAL_PODS=$MAX_TOTAL_PODS
    fi
    if [ "$TOTAL_PODS" -gt "$MAX_TOTAL_PODS" ]; then
        echo "TOTAL_PODS ($TOTAL_PODS) supera el máximo permitido ($MAX_TOTAL_PODS), se ajusta"
        TOTAL_PODS=$MAX_TOTAL_PODS
    fi

    # Validar MAX_CONCURRENT_PODS
    if ! [[ "$MAX_CONCURRENT_PODS" =~ ^[0-9]+$ ]] || [ "$MAX_CONCURRENT_PODS" -lt 1 ]; then
        echo "MAX_CONCURRENT_PODS inválido ($MAX_CONCURRENT_PODS), se ajusta a $MAX_PARALLEL_PODS"
        MAX_CONCURRENT_PODS=$MAX_PARALLEL_PODS
    fi
    if [ "$MAX_CONCURRENT_PODS" -gt "$MAX_PARALLEL_PODS" ]; then
        echo "MAX_CONCURRENT_PODS ($MAX_CONCURRENT_PODS) supera el límite paralelo ($MAX_PARALLEL_PODS), se ajusta"
        MAX_CONCURRENT_PODS=$MAX_PARALLEL_PODS
    fi
    if [ "$MAX_CONCURRENT_PODS" -gt "$TOTAL_PODS" ]; then
        echo "MAX_CONCURRENT_PODS ($MAX_CONCURRENT_PODS) es mayor que TOTAL_PODS ($TOTAL_PODS), se ajusta"
        MAX_CONCURRENT_PODS=$TOTAL_PODS
    fi
}
ask_defaults() {
    if [[ -z "${1:-}" ]]; then
        echo "No has pasado parámetros. ¿Quieres usar valores por defecto? (s/n)"
        read -r resp
        if [[ "$resp" == "s" ]]; then
            WORKERS="$DEFAULT_WORKERS"
            TOTAL_PODS="$MAX_TOTAL_PODS"
            MAX_CONCURRENT_PODS="$MAX_PARALLEL_PODS"
        else
            echo "Ejecuta de nuevo usando:"
            echo "  ./start.sh <WORKERS> <TOTAL_PODS> <MAX_CONCURRENT_PODS>"
            exit 1
        fi
    fi
}
main() {
    show_banner

    # Validar parámetros
    # Procesar opciones de ayuda 
     ask_defaults
    
    # Mostrar info de límites y validar argumentos
    show_limits_info
    validate_args

    echo "Configuración final:"
    echo "  Workers: $WORKERS"
    echo "  Total Pods: $TOTAL_PODS"
    echo "  Pods en paralelo: $MAX_CONCURRENT_PODS"

    delete_cluster_if_exists "$CLUSTER_NAME"
    check_dependencies
    create_cluster

    # CONFIGURAR ETIQUETAS Y TAINTS ANTES DE CREAR EL SCHEDULER
    configure_node_labels_and_taints "$CLUSTER_NAME"
    
    create_namespace
    cleanup_old_pods
    create_scheduler_custom
    load_image_in_cluster
    install_metrics_server
    local start_time
    start_time=$(date +%s)

    # Ejecutar la creación de pods
    if create_pods_parallel_from_yaml; then
        info "Todos los pods se completaron exitosamente"
    else
        local pod_exit_code=$?
        warn "Algunos pods fallaron con código: $pod_exit_code"
    fi

    local end_time
    end_time=$(date +%s)

    local duration=$((end_time - start_time))
    info "Tiempo total de ejecución: ${duration} segundos"

    # Calcular throughput
    if command -v bc >/dev/null 2>&1; then
        local throughput
        throughput=$(echo "scale=2; $TOTAL_PODS / $duration" | bc)
        info "Throughput: $throughput pods/segundo"
    else
        local approx_throughput
        approx_throughput=$(awk 'BEGIN {printf "%.2f", '"$TOTAL_PODS"' / '"$duration"'}')
        info "Throughput: $approx_throughput pods/segundo (aproximado)"
    fi

    # Mostrar métricas
    show_performance_metrics

    # Entrar en el menú de gestión interactivo
    management_menu

    exit 0
}

# Manejar interrupciones
trap 'echo ""; info "Interrumpido por usuario"; exit 1' SIGINT

# Ejecutar script principal
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
else
    main "$@"
fi
