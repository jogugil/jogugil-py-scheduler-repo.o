#!/bin/bash

# ========================================
# LOGGING MÍNIMO Y PORTÁTIL
# ========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
LOG_FILE="$LOG_DIR/benchmarking.log"
mkdir -p "$LOG_DIR"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Nivel de log: 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG
LOG_LEVEL=${LOG_LEVEL:-4}

# Array global para almacenar PIDs de procesos en segundo plano
declare -a BACKGROUND_PIDS=()

# Función para registrar procesos en segundo plano
register_background_pid() {
    local pid=$1
    BACKGROUND_PIDS+=($pid)
    log "DEBUG" "Registrado proceso en segundo plano PID: $pid"
}

# Función para matar todos los procesos en segundo plano
kill_background_processes() {
    if [ ${#BACKGROUND_PIDS[@]} -gt 0 ]; then
        log "INFO" "Deteniendo ${#BACKGROUND_PIDS[@]} procesos en segundo plano..."
        
        # Primero enviar SIGTERM
        for pid in "${BACKGROUND_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log "DEBUG" "Enviando SIGTERM a proceso $pid"
                kill "$pid" 2>/dev/null
            fi
        done
        
        # Esperar un poco
        sleep 3
        
        # Forzar terminación si es necesario
        for pid in "${BACKGROUND_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log "DEBUG" "Forzando terminación de proceso $pid"
                kill -9 "$pid" 2>/dev/null
            fi
        done
        
        # Limpiar el array
        BACKGROUND_PIDS=()
        log "INFO" "Todos los procesos en segundo plano detenidos"
    fi
}


# Función de logging mejorada con timestamp en pantalla
log() {
    local level=$1
    shift
    local msg="$*"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Escribir en archivo con formato completo
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"

    # Mostrar en pantalla con colores Y TIMESTAMP
    case "$level" in
        DEBUG)
            if [[ $LOG_LEVEL -ge 4 ]]; then
                echo -e "${BLUE}[$timestamp] [DEBUG] $msg${NC}"
            fi
            ;;
        INFO)
            if [[ $LOG_LEVEL -ge 3 ]]; then
                echo "[$timestamp] [INFO] $msg"
            fi
            ;;
        WARN)
            if [[ $LOG_LEVEL -ge 2 ]]; then
                echo -e "${YELLOW}[$timestamp] [WARN] $msg${NC}"
            fi
            ;;
        ERROR)
            if [[ $LOG_LEVEL -ge 1 ]]; then
                echo -e "${RED}[$timestamp] [ERROR] $msg${NC}" >&2
            fi
            ;;
        SUCCESS)
            echo -e "${GREEN}[$timestamp] [SUCCESS] $msg${NC}"
            ;;
        *)
            if [[ $LOG_LEVEL -ge 3 ]]; then
                echo "[$timestamp] [INFO] $msg"
            fi
            ;;
    esac
}

# Ejecutar un comando "seguro" que no detenga el script si falla
safe_run() {
    "$@" || log "WARN" "Comando '$*' falló pero se ignora"
}

# Manejo de errores ROBUSTO - detiene TODO inmediatamente
enable_error_trapping() {
    set -eE -o pipefail
    trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR
    trap 'exit_handler' EXIT INT TERM
}

# Handler para salidas normales
exit_handler() {
    local exit_code=$?
    log "DEBUG" "Ejecutando exit handler (código: $exit_code)"
    kill_background_processes
}

# Handler para errores - DETIENE TODO INMEDIATAMENTE

error_handler() {
    local line=$1
    local command=$2
    local exit_code=$3

    # Solo manejar errores verdaderamente críticos, ignorar errores menores
    case $exit_code in
        0|130|124|1) 
            # Códigos de salida no críticos: éxito, Ctrl+C, timeout, error genérico
            log "DEBUG" "Error no crítico en línea $line: '$command' (exit code: $exit_code)"
            return 0
            ;;
        *)
            log "ERROR" "❌ ERROR CRÍTICO en línea $line: '$command' (exit code: $exit_code)"
            
            # Matar procesos en segundo plano solo para errores verdaderamente críticos
            log "ERROR" "Deteniendo todos los procesos en segundo plano..."
            kill_background_processes

            # Limpiar recursos de Kubernetes si es posible
            log "ERROR" "Limpiando recursos de Kubernetes..."
            safe_run kubectl delete --all pods --namespace test-scheduler --ignore-not-found=true
            safe_run kubectl delete pods --namespace default --field-selector=status.phase!=Succeeded --ignore-not-found=true

            echo -e "\n${RED}❌ ERROR CRÍTICO - Deteniendo ejecución${NC}"
            echo -e "${YELLOW}Revisa el log: $LOG_FILE${NC}"

            exit $exit_code
            ;;
    esac
}
# Mostrar info del log al cargar
log "DEBUG" "📁 Log: $LOG_FILE"
