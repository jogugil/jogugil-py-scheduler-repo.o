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
LOG_LEVEL=${LOG_LEVEL:-3}

log() {
    local level=$1
    shift
    local msg="$*"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Escribir en archivo
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
    
    # Mostrar en pantalla con colores
    case "$level" in
        DEBUG)
            [[ $LOG_LEVEL -ge 4 ]] && echo -e "${BLUE}[DEBUG] $msg${NC}"
            ;;
        WARN)
            [[ $LOG_LEVEL -ge 2 ]] && echo -e "${YELLOW}[WARN] $msg${NC}"
            ;;
        ERROR)
            [[ $LOG_LEVEL -ge 1 ]] && echo -e "${RED}[ERROR] $msg${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS] $msg${NC}"
            ;;
        *)
            [[ $LOG_LEVEL -ge 3 ]] && echo "[INFO] $msg"
            ;;
    esac
}

# Manejo de errores más simple y robusto
enable_error_trapping() {
    set -e
    trap '[[ $? -ne 0 ]] && handle_error ${LINENO} "${BASH_COMMAND}"' ERR
}

handle_error() {
    local line=$1
    local command=$2
    local code=$?
    
    log "ERROR" "Falló en línea $line: '$command' (exit code: $code)"
    echo -e "\n${RED}❌ ERROR CRÍTICO - Deteniendo ejecución${NC}"
    echo -e "${YELLOW}Revisa el log: $LOG_FILE${NC}"
    exit $code
}

# Mostrar info del log al cargar
echo -e "${GREEN}📁 Log: $LOG_FILE${NC}"
