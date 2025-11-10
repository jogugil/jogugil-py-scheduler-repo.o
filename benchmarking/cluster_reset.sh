#!/bin/bash
set -e

echo "=== Eliminando recursos del clúster ==="
kubectl delete --all pods --all-namespaces || true
kubectl delete --all deployments --all-namespaces || true
kubectl delete --all services --all-namespaces || true
kubectl delete --all configmaps --all-namespaces || true

echo "=== Eliminando imágenes Docker locales ==="
docker image rm -f cpu-heavy:latest ram-heavy:latest scheduler:latest || true

echo "=== Eliminando contenedores detenidos ==="
docker container prune -f

echo "=== Listo para reconstruir imágenes y recargar el clúster ==="
