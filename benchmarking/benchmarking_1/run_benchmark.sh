#!/bin/bash

# ========================================
# SCRIPT PRINCIPAL - BENCHMARKING
# ========================================

# Cargar logger
source ./logger.sh

# ========================================
# ROTAR LOG ANTERIOR Y MARCAR INICIO
# ========================================

if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "$LOG_DIR/benchmarking_$(date -u +"%Y%m%dT%H%M%S").log" 2>/dev/null || true
fi
touch "$LOG_FILE"

log "INFO" "================== INICIO DE EJECUCIÓN =================="
log "INFO" "Fecha: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ========================================
# PARÁMETROS Y OPCIONES
# ========================================

log "INFO" "Parámetros recibidos: $*"

# Variables por defecto
SCHED_IMPL="watch"
NUM_PODS="20"
VERBOSE=false

# Parsear opciones
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            export LOG_LEVEL=4  # Nivel DEBUG máximo
            log "INFO" "🔍 MODO VERBOSO ACTIVADO - Mostrando DEBUG, auditorías y checkpoints"
            shift
            ;;
        watch|polling)
            SCHED_IMPL="$1"
            shift
            ;;
        [0-9]*)
            NUM_PODS="$1"
            shift
            ;;
        *)
            log "WARN" "Parámetro desconocido: $1"
            shift
            ;;
    esac
done

# Si no verbose, establecer nivel normal (solo INFO y SUPERIOR)
if [ "$VERBOSE" = false ]; then
    export LOG_LEVEL=3  # Solo INFO, WARN, ERROR, SUCCESS
fi

# Si no se pasaron parámetros específicos
if [[ $SCHED_IMPL == "watch" && $NUM_PODS == "20" && $VERBOSE == false ]]; then
    log "INFO" "No se pasaron parámetros, usando valores por defecto: watch 20 (modo normal)"
fi

log "INFO" "Configuración final - Scheduler: $SCHED_IMPL, Pods: $NUM_PODS, Verbose: $VERBOSE"

# Validar valores
if [[ "$SCHED_IMPL" != "watch" && "$SCHED_IMPL" != "polling" ]]; then
    log "ERROR" "Scheduler debe ser 'watch' o 'polling', no '$SCHED_IMPL'"
    exit 1
fi

if ! [[ "$NUM_PODS" =~ ^[0-9]+$ ]]; then
    log "ERROR" "Número de pods debe ser numérico, no '$NUM_PODS'"
    exit 1
fi

# ========================================
# CONFIGURAR MANEJO DE ERRORES
# ========================================

enable_error_trapping

# ========================================
# BANNER DE INICIO
# ========================================

echo -e "${GREEN}"
echo "========================================"
echo "   BENCHMARKING - SCHEDULER"
echo "   Tipo: $SCHED_IMPL"
echo "   Pods: $NUM_PODS"
echo "   Verbose: $VERBOSE"
echo "========================================"
echo -e "${NC}"

# Mostrar ayuda de verbose si está activado
if [ "$VERBOSE" = true ]; then
    echo -e "${BLUE}"
    echo "🔍 MODO VERBOSO ACTIVADO:"
    echo "   - Se muestran mensajes DEBUG"
    echo "   - Se muestran auditorías completas" 
    echo "   - Se muestran todos los checkpoints"
    echo "   - Log level: DEBUG (4)"
    echo -e "${NC}"
else
    echo -e "${GREEN}"
    echo "📝 MODO NORMAL:"
    echo "   - Solo mensajes INFO y SUPERIOR"
    echo "   - Auditorías y checkpoints ocultos"
    echo "   - Log level: INFO (3)"
    echo -e "${NC}"
fi

# ========================================
# MANEJO DE SEÑALES
# ========================================

propagate_signal() {
    log "INFO" "Propagando señal a procesos hijos..."
    kill_all_background_processes
    exit 1
}
trap propagate_signal SIGINT SIGTERM

# ========================================
# EJECUTAR SETUP
# ========================================

log "INFO" "🚀 Iniciando benchmarking setup..."

if [ "$VERBOSE" = true ]; then
    log "DEBUG" "Ejecutando: ./benchmarking_setup.sh $SCHED_IMPL $NUM_PODS"
    log "DEBUG" "=== INFORMACIÓN DE EJECUCIÓN VERBOSA ==="
    log "DEBUG" "Directorio actual: $(pwd)"
    log "DEBUG" "Usuario: $(whoami)"
    log "DEBUG" "Log file: $LOG_FILE"
    log "DEBUG" "Checkpoint file: $CHECKPOINT_FILE"
fi

if safe_run ./benchmarking_setup.sh "$SCHED_IMPL" "$NUM_PODS"; then
    log "SUCCESS" "Benchmarking completado exitosamente"
    echo -e "${GREEN}📄 Log completo en: $LOG_FILE${NC}"
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}🔍 Checkpoints detallados en: $CHECKPOINT_FILE${NC}"
    fi
else
    exit_code=$?
    log "ERROR" "Benchmarking falló con código: $exit_code"
    echo -e "${RED}❌ ERROR - Revisa el log: $LOG_FILE${NC}"
    exit $exit_code
fi
