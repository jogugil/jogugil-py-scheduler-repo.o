#!/bin/bash
set -e

# =========================
# Funciones para generar imágenes
# =========================

build_cpu_heavy_image() {
    echo "=== Construyendo imagen CPU-heavy ==="
    docker build -t cpu-heavy:latest ./cpu-heavy
}

build_ram_heavy_image() {
    echo "=== Construyendo imagen RAM-heavy ==="
    docker build -t ram-heavy:latest ./ram-heavy
}

build_scheduler_image() {
    echo "=== Preparando Dockerfile y requirements para Scheduler ==="
    cp ../../Dockerfile ./
    cp ../../requirements.txt ./
    
    echo "=== Construyendo imagen Scheduler ==="
    docker build -t scheduler:latest .
}

# =========================
# Función para cargar imágenes en todos los nodos del clúster
# =========================
load_image_to_nodes() {
    local image_name=$1
    echo "=== Cargando imagen $image_name en todos los nodos del clúster ==="

    nodes=$(kubectl get nodes -o name)
    for node in $nodes; do
        echo "Cargando $image_name en $node"
        if kind get clusters &>/dev/null; then
            # kind
            kind load docker-image "$image_name" --name $(kind get clusters)
        else
            # minikube
            minikube image load "$image_name" --nodes $node
        fi
    done

    echo "=== Imagen $image_name cargada en todos los nodos ==="
}

# =========================
# Ejecución principal
# =========================

echo "=== Construyendo imágenes CPU-heavy y RAM-heavy ==="
build_cpu_heavy_image
build_ram_heavy_image

echo "=== Construyendo imagen Scheduler ==="
build_scheduler_image

echo "=== Cargando imágenes en todos los nodos del clúster ==="
load_image_to_nodes cpu-heavy:latest
load_image_to_nodes ram-heavy:latest
load_image_to_nodes scheduler:latest

echo "=== Todas las imágenes construidas y cargadas en el clúster ==="
