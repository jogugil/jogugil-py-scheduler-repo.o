#!/bin/bash
set -e

CLUSTER_NAME="sched-lab"
NAMESPACE="test-scheduler"
SCHEDULER_NAME="my-scheduler"
SCHEDULER_IMAGE="my-py-scheduler:latest"

echo "=== DIAGNÓSTICO COMPLETO DEL SCHEDULER ==="

# 0. Eliminar cluster existente y crear uno nuevo
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "🚨 Cluster existente detectado. Eliminando..."
    kind delete cluster --name $CLUSTER_NAME
fi

echo "Creando cluster $CLUSTER_NAME..."
kind create cluster --name $CLUSTER_NAME --config kind-config.yaml
sleep 10

# 1. Verificar cluster básico
echo "1. VERIFICANDO CLUSTER:"
kubectl cluster-info
kubectl get nodes

# 2. Construir y cargar la imagen del scheduler
echo ""
echo "2. CONSTRUYENDO Y CARGANDO IMAGEN DEL SCHEDULER"
docker build --no-cache -t $SCHEDULER_IMAGE .
kind load docker-image $SCHEDULER_IMAGE --name $CLUSTER_NAME --nodes sched-lab-control-plane
docker exec -it sched-lab-control-plane crictl images | grep $SCHEDULER_IMAGE || true

# 3. Crear namespace para pruebas
echo ""
echo "3. CREANDO NAMESPACE PARA PRUEBAS"
kubectl create namespace $NAMESPACE || echo "Namespace $NAMESPACE ya existe"

# 4. Desplegar scheduler custom
echo ""
echo "4. DESPLEGANDO SCHEDULER CUSTOM"
kubectl apply -f rbac-deploy.yaml
kubectl get deployment -n kube-system
kubectl get pods -n kube-system

# 5. Configurar labels y taints en nodos
echo ""
echo "5. CONFIGURANDO LABELS Y TAINTS EN NODOS"
kubectl label node sched-lab-control-plane env=prod --overwrite
kubectl label node sched-lab-worker env=prod --overwrite
kubectl label node sched-lab-worker3 env=prod --overwrite
kubectl taint nodes sched-lab-worker3 example=true:NoSchedule --overwrite
kubectl get nodes -o custom-columns=NAME:.metadata.name,ENV:.metadata.labels.env,TAINTS:.spec.taints

# 6. Crear pods de test
echo ""
echo "6. CREANDO PODS DE TEST"
echo "Aplicando pods de test..."
kubectl delete pod test-pod test-nginx-pod test-worker3-pod -n $NAMESPACE --ignore-not-found=true
sleep 2
kubectl apply -f test-pod.yaml
kubectl apply -f test-nginx-pod.yaml
kubectl apply -f test-worker3-pod.yaml -n $NAMESPACE

# 7. Esperar y verificar
echo ""
echo "7. ESPERANDO Y VERIFICANDO:"
SCHEDULER_POD=$(kubectl get pods -n kube-system -l app=$SCHEDULER_NAME -o jsonpath='{.items[0].metadata.name}')
for i in {1..30}; do
    echo "Intento $i/30:"
    ALL_READY=true
    PODS=$(kubectl get pods -n $NAMESPACE -o json)
    for pod_name in $(echo "$PODS" | jq -r '.items[].metadata.name'); do
        ready=$(echo "$PODS" | jq -r ".items[] | select(.metadata.name==\"$pod_name\") | .status.containerStatuses[0].ready")
        if [ "$ready" != "true" ]; then
            ALL_READY=false
        fi
    done

    kubectl get pods -n $NAMESPACE

    if [ "$ALL_READY" = true ]; then
        echo "✅ Todos los pods están en Running"
        break
    fi

    sleep 15
done

# 8. Diagnóstico final
echo ""
echo "8. DIAGNÓSTICO FINAL:"
sleep 4
echo "8.1 Estado del scheduler:"
kubectl get pods -l app=my-scheduler

echo "8.2 Logs del scheduler:"
kubectl logs -l app=my-scheduler --tail=50

echo "8.3 Nodos y sus taints:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

echo "8.4 Pods y sus scheduler:"
kubectl get pods -n test-scheduler -o custom-columns=NAME:.metadata.name,SCHEDULER:.spec.schedulerName,NODE:.spec.nodeName

echo "8.5 Ver estado de los pods:"
kubectl get pods -n test-scheduler -o wide
echo "8.6 Revisar eventos del namespace:"
kubectl get events -n test-scheduler --sort-by='.metadata.creationTimestamp'


