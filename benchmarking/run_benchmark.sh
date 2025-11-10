#!/bin/bash

# ========================================
# SCRIPT PRINCIPAL - PASA PARÁMETROS
# ========================================

# Cargar logging
source ./logger.sh

# Mostrar parámetros recibidos
log "INFO" "Parámetros recibidos: $*"

# Validar parámetros
if [[ $# -eq 0 ]]; then
    log "WARN" "No se pasaron parámetros, usando valores por defecto: watch 20"
    SCHED_IMPL="watch"
    NUM_PODS="20"
elif [[ $# -eq 1 ]]; then
    SCHED_IMPL="$1"
    NUM_PODS="20"
    log "INFO" "Usando scheduler: $SCHED_IMPL, pods por defecto: $NUM_PODS"
else
    SCHED_IMPL="$1"
    NUM_PODS="$2"
    log "INFO" "Usando scheduler: $SCHED_IMPL, pods: $NUM_PODS"
fi

# Validar valores
if [[ "$SCHED_IMPL" != "watch" && "$SCHED_IMPL" != "polling" ]]; then
    log "ERROR" "Scheduler debe ser 'watch' o 'polling', no '$SCHED_IMPL'"
    exit 1
fi

if ! [[ "$NUM_PODS" =~ ^[0-9]+$ ]]; then
    log "ERROR" "Número de pods debe ser numérico, no '$NUM_PODS'"
    exit 1
fi

# Configurar manejo de errores
enable_error_trapping

# Banner de inicio
echo -e "${GREEN}"
echo "========================================"
echo "   BENCHMARKING - SCHEDULER"
echo "   Tipo: $SCHED_IMPL"
echo "   Pods: $NUM_PODS"
echo "========================================"
echo -e "${NC}"

log "INFO" "🚀 Iniciando benchmarking setup..."

# EJECUTAR EL SETUP PASANDO LOS PARÁMETROS
log "INFO" "Ejecutando: ./benchmarking_setup.sh $SCHED_IMPL $NUM_PODS"
./benchmarking_setup.sh "$SCHED_IMPL" "$NUM_PODS"

# Si llegamos aquí, todo fue exitoso
log "SUCCESS" "Benchmarking completado exitosamente"
echo -e "${GREEN}📄 Log completo en: $LOG_FILE${NC}"
