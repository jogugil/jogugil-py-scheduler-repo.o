#!/bin/bash

CLUSTER_NAME="sched-lab"
NAMESPACE="test-scheduler"
SCHEDULER_NAME="my-scheduler"

echo "=== DIAGNÓSTICO COMPLETO DEL SCHEDULER ==="

# 0. Verificar cluster básico
echo "1. VERIFICANDO CLUSTER:"
kubectl cluster-info
echo "Nodos:"
kubectl get nodes

# 1. Verificar recursos de RBAC
echo "1. RECURSOS RBAC:"
echo "   - ClusterRole: $(kubectl get clusterrole my-scheduler-clusterrole -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'NO EXISTE')"
echo "   - ClusterRoleBinding: $(kubectl get clusterrolebinding my-scheduler-clusterrolebinding -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'NO EXISTE')"
echo "   - ServiceAccount: $(kubectl get serviceaccount -n kube-system my-scheduler -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'NO EXISTE')"



# 2. Verificar el scheduler
echo ""
echo "2. VERIFICANDO SCHEDULER:"
kubectl get deployment -n kube-system $SCHEDULER_NAME
SCHEDULER_POD=$(kubectl get pods -n kube-system -l app=$SCHEDULER_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$SCHEDULER_POD" ]]; then
    echo "✅ Pod del scheduler: $SCHEDULER_POD"
    echo "Estado: $(kubectl get pod -n kube-system $SCHEDULER_POD -o jsonpath='{.status.phase}')"
else
    echo "❌ No se encuentra el pod del scheduler"
    exit 1
fi

# 3. Verificar logs del scheduler
echo ""
echo "3. LOGS DEL SCHEDULER:"
kubectl logs -n kube-system $SCHEDULER_POD --tail=20

# 4. Verificar RBAC
echo ""
echo "4. VERIFICANDO RBAC:"
kubectl get clusterrole,clusterrolebinding -l app=$SCHEDULER_NAME

# 5. Verificar namespace y pods de test
echo ""
echo "5. VERIFICANDO NAMESPACE Y PODS:"
kubectl get namespaces | grep $NAMESPACE || echo "❌ Namespace $NAMESPACE no existe"
echo "Pods en $NAMESPACE:"
kubectl get pods -n $NAMESPACE

# 6. Verificar que los pods usen el scheduler correcto
echo ""
echo "6. VERIFICANDO SCHEDULERNAME DE LOS PODS:"
for pod in $(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}'); do
    scheduler=$(kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.spec.schedulerName}' 2>/dev/null || echo "default-scheduler")
    echo "Pod $pod -> Scheduler: $scheduler"
done

# 7. Verificar eventos recientes
echo ""
echo "7. EVENTOS RECIENTES:"
kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp --tail=10

# 8. Crear pods de test si no existen
echo ""
echo "8. CREANDO PODS DE TEST:"

# Pod 1: test-pod
cat > test-pod-fixed.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: $NAMESPACE
spec:
  schedulerName: $SCHEDULER_NAME
  containers:
  - name: test-container
    image: busybox
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF

# Pod 2: test-nginx-pod  
cat > test-nginx-pod-fixed.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-nginx-pod
  namespace: $NAMESPACE
spec:
  schedulerName: $SCHEDULER_NAME
  containers:
  - name: nginx
    image: nginx:latest
  restartPolicy: Never
EOF

echo "Aplicando pods de test..."
kubectl delete pod test-pod -n $NAMESPACE --ignore-not-found=true
kubectl delete pod test-nginx-pod -n $NAMESPACE --ignore-not-found=true
sleep 2

kubectl apply -f test-pod-fixed.yaml
kubectl apply -f test-nginx-pod-fixed.yaml

# 9. Esperar y ver resultados
echo ""
echo "9. ESPERANDO Y VERIFICANDO:"
for i in {1..30}; do
    echo "Intento $i/30:"
    kubectl get pods -n $NAMESPACE
    
    # Verificar si algún pod fue programado por nuestro scheduler
    SCHEDULER_LOGS=$(kubectl logs -n kube-system $SCHEDULER_POD --tail=10 2>/dev/null | grep -E "(Processing|Bound|Scheduled)" || true)
    if [[ -n "$SCHEDULER_LOGS" ]]; then
        echo "✅ Logs del scheduler encontrados:"
        echo "$SCHEDULER_LOGS"
        break
    fi
    
    sleep 5
done

# 10. Diagnóstico final
echo ""
echo "10. DIAGNÓSTICO FINAL:"
echo "Pods en el sistema:"
kubectl get pods -A --field-selector=status.phase=Pending

echo ""
echo "Si no ves actividad del scheduler, revisa:"
echo "1. Los YAML deben tener 'schedulerName: $SCHEDULER_NAME'"
echo "2. El scheduler debe tener permisos RBAC para ver y bind pods"
echo "3. El scheduler debe estar escuchando en el namespace correcto"
