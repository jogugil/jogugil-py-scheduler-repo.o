#=======================================================
## Autores

- **José Javier Gutiérrez Gil** ([jogugil@gmail.com]) – Propietario y responsable principal del código  
- **Javier Díaz León** ([JavierDiazL - javidi2001@gmail.com]) – Colaborador  
- **Francesc** ([cescdovi@gmail.com]) – Colaborador  

## Licencias

[![Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0)  
Código fuente bajo **Apache License 2.0**  

[![CC BY-NC 4.0](https://img.shields.io/badge/License-CC%20BY--NC%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc/4.0/)  
Documentación, PDFs e imágenes bajo **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)**
#===============================================================

## Descripción

Este script permite crear y gestionar pods de prueba en Kubernetes, controlar la concurrencia, monitorizar el estado y limitar recursos de CPU y memoria para pruebas de estrés.

En este directorio se tienen dos scripts para recrear dos pequeños benchmarking:

* ***benchmarking_1/*** : Script algo más complejo, más verbose y con el cálculo de diversas mñetricas ademñas del consumo de cpu y memoria que me da el servidor de métricas 
instaldo en el clúster. 
Además, mantiene un control de logger y de fichero de métricas en json. 
```Bash
./run_benchmarking.sh <número de pods en paralelo> <número de pods totales>
```
Seejecutan a la vez diferntes scripts (logger.sh, benchmarking_setaup.sh). Y mantenemos un script de ejecución de pods y cálculo de métricas (scheduler-test.sh)


* ***benchmarking_2/***: Script más simple donde ademñas aparece un menu para poder visualizar los logs y eventos tanto de los pods creados cómo del scheduler personalizado. 
se ejecuta con :
```Bash
./start.sh <número de pods en paralelo> <número de pods totales>
```



# Cuestiones a tener en cuenta


Por defecto se crea el cluster con 1 Control Plane y dos workers. Además existe una opción apra recrear otro clúster donde se puede indicar el número 
de workers y de pods a ejecutar. 
En este script se límita las máteicas al consumo de cpu y de memoria Ram.

Pequeño benchmarking que carga diferentes Pods con contenedores de dferete carga cpu, Ram, y operaciones para poder contratar un poco mejor lso diferntes tipos de schedulers  implementados (polling vs watch).

En nuestro ejemplo tendremos tres nodos:
1. Control Plane (Master)
2. Worker
3. Woerker2

En el desarrollo del `benchmarking`nos hemos topado con algo interesante. En `kubernetes`no basta con forzar la carga de la imagen de `my-py-schewduler` en el `Control plane`. Sino que tenemos que modificar su manifiesto par a oibligar y decirle a `kubernetes`que  el `deployment`de `my-scheduler`se debe programar en el `control-plane`. Sino lo ahcemos así, al tener varios nodos, kubernetes lo programa donde ve, como vemos en la traza de log de la primera ejecución del bechmarking:

```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/repositorio/jogugil-py-scheduler-repo.o$ kubectl -n kube-system get pods -l app=my-scheduler -o wide
NAME                            READY   STATUS              RESTARTS   AGE   IP           NODE                NOMINATED NODE   READINESS GATES
my-scheduler-6fbbc9c795-wlrfq   0/1     ErrImageNeverPull   0          75s   10.244.1.3   sched-lab-worker2   <none>           <none>
```
En este caso, kubernetes intento programar `my-scheduler`en `sched-lab-worker2`y fallo porque ahi no tiene la imagen cargada. 

<img width="1039" height="631" alt="image" src="https://github.com/user-attachments/assets/3062ece7-4cf7-40a8-a016-6e3066fbe919" />

```Bash
serviceaccount/my-scheduler created
clusterrolebinding.rbac.authorization.k8s.io/my-scheduler-binding created
deployment.apps/my-scheduler created
Waiting for deployment "my-scheduler" rollout to finish: 0 of 1 updated replicas are available...
error: timed out waiting for the condition
```

Para solucionarlo añadimos en el manifiesto de `my-py-scheduler` un `nodeSelector` y un `tolerations`. Notar que no es suficiente, en este caso, añadir sólo un `nodeSelector` porque el nodo control-plane tiene el taint node-role.kubernetes.io/control-plane:NoSchedule. Ese taint bloquea cualquier pod que no tenga toleración.

Para que funcione, además del nodeSelector, debes agregar en tu spec del pod o Deployment la tolerancia correspondiente:
```yaml
tolerations:
- key: "node-role.kubernetes.io/control-plane"
  operator: "Exists"
  effect: "NoSchedule"
```
Con eso, le estamos diciendo a Kubernetes: “este pod puede ignorar el taint del control-plane y programarse aquí”.

Por tanto el manifiesto de `rbac-deploy.yaml` queda:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-scheduler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-scheduler-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-scheduler
subjects:
- kind: ServiceAccount
  name: my-scheduler
  namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-scheduler
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: my-scheduler}
  template:
    metadata:
      labels: {app: my-scheduler}
    spec:
      serviceAccountName: my-scheduler
      nodeSelector:
        kubernetes.io/hostname: sched-lab-control-plane
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: scheduler
        imagePullPolicy: Never
        image: my-py-scheduler:latest
        args: ["--scheduler-name","my-scheduler"]
```


### Limitación número de **workers** y númerop de **pods*

Hemos limitado el número de workers y pods mediante las variables **DEFAULT_WORKERS**, **MAX_TOTAL_PODS** 
y **MAX_PARALLEL_PODS**, porque en numerosas ocasiones al crear el clúster los procesos se terminaban abruptamente 
mostrando el **código de salida 137**, debido a falta de memoria en el host (OOM Killer).


Intentamos implementar una función (limit_worker_resources()) para limitar CPU y memoria directamente en los nodos worker, 
pero no tuvimos éxito en todos los casos. Por ello, actualmente solo limitamos los pods a través de su manifiesto, utilizando 
las secciones resources.requests y resources.limits para definir memoria y CPU:

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "0.2"
  limits:
    memory: "512Mi"
    cpu: "0.5"
```

```bash
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
```


Además, seguimos limitando el número de workers y pods mediante las variables DEFAULT_WORKERS, MAX_TOTAL_PODS y MAX_PARALLEL_PODS, ya que en varias ocasiones la creación del clúster terminaba abruptamente con código de salida 137 por falta de memoria en el host.

***Ejemplo código del error:***

```Bash
 kubectl get pod cpu-heavy-pod-hpp2g -n test-scheduler -o json | jq '.status.containerStatuses[0].state.terminated'
{
  "containerID": "containerd://af57843a3912b9c56fe1fcdf59124a960c748e0906a9fb77af2dc55bb27707f2",
  "exitCode": 137,
  "finishedAt": "2025-11-16T11:43:41Z",
  "reason": "Error",
  "startedAt": "2025-11-16T11:43:39Z"
}
```

AÜN EN DESARROLLO Y PRUEBAS!!!!




# Glosario de Comandos Kubernetes para el Proyecto
Este glosario proporciona una referencia rápida para todas las operaciones de monitoreo y troubleshooting necesarias en el proyecto de Kubernetes.

## Uso en el Proyecto : El proposito es monitorear el estado, los roles y la capacidad de los nodos del cluster entrte otros.

* Monitoreo del Scheduler Personalizado: Verificar que el scheduler esté funcionando correctamente

* Depuración de Problemas: Identificar pods pendientes, fallidos o con problemas de programación

* Optimización de Recursos: Monitorear el uso de CPU y memoria en el cluster

* Validación de Configuración: Verificar que los pods usen el scheduler correcto

* Auditoría del Sistema: Revisar eventos y logs para troubleshooting

## Índice de Comandos
### 1. Verificación del Estado del Cluster

* Nodos
```bash
# Verificar el estado y información detallada de los nodos
kubectl get nodes -o wide
```
* Estado General del Cluster
```bash
# Verificar la información general del cluster
kubectl cluster-info dump

# Listar todos los recursos de la API disponibles
kubectl api-resources
```

### 2. Gestión y Monitoreo de Pods
* Pods en Todos los Namespaces
```bash
# Listar todos los pods del cluster
kubectl get pods --all-namespaces

# Verificar pods en el namespace específico del proyecto
kubectl get pods -n test-scheduler
```

* Pods por Estado
```bash
# Pods pendientes de programación
kubectl get pods -n test-scheduler --field-selector=status.phase=Pending

# Pods en ejecución
kubectl get pods -n test-scheduler --field-selector=status.phase=Running

# Pods fallidos
kubectl get pods -n test-scheduler --field-selector=status.phase=Failed

# Pods completados exitosamente
kubectl get pods -n test-scheduler --field-selector=status.phase=Succeeded

# Pods en estado desconocido
kubectl get pods -n test-scheduler --field-selector=status.phase=Unknown
```

### 3. Scheduler Personalizado
* Verificación del Scheduler
```bash
# Verificar los pods del scheduler personalizado
kubectl get pods -n kube-system -l app=my-scheduler

# Verificar los logs del scheduler personalizado
kubectl logs -n kube-system -l app=my-scheduler

# Verificar la configuración del scheduler en los pods
kubectl get pods -n test-scheduler -o yaml | grep schedulerName
```
### 4. Monitoreo de Eventos
* Eventos del Namespace

```bash
# Verificar eventos en el namespace del proyecto
kubectl get events -n test-scheduler

# Verificar eventos a nivel de todo el cluster
kubectl get events --all-namespaces
```
### 5. Gestión de Recursos y Métricas
* Métricas de Recursos
```bash
# Verificar uso de recursos en nodos
kubectl top nodes

# Verificar uso de recursos en pods del proyecto
kubectl top pods -n test-scheduler

# Verificar uso de recursos en pods del sistema
kubectl top pods -n kube-system
```
* Límites y Cuotas
```bash
# Verificar límites de recursos en namespaces
kubectl describe namespace test-scheduler

# Verificar cuotas de recursos
kubectl get resourcequotas --all-namespaces

# Verificar límites en pods específicos
kubectl describe pod -n test-scheduler <pod-name>
```
### 6. Componentes del Sistema
* DaemonSets y Deployments
```bash
# Verificar DaemonSets y Deployments en kube-system
kubectl get daemonsets,deployments -n kube-system
```
* Servicios
```bash
# Verificar servicios en todos los namespaces
kubectl get services --all-namespaces
```
### 7. Almacenamiento
* Volúmenes Persistentes
```bash
# Verificar Persistent Volumes y Claims
kubectl get pv,pvc --all-namespaces

# Verificar Storage Classes
kubectl get storageclass
```
### 8. Redes y Seguridad
* Network Policies
```bash
# Verificar políticas de red
kubectl get networkpolicies --all-namespaces

# Verificar definiciones de red
kubectl get netattdefs --all-namespaces
```
### 9. Logs y Depuración
* Logs de Pods
```bash
# Verificar logs de pods específicos
kubectl logs -n test-scheduler <pod-name>

# Verificar logs de pods que fallan
kubectl logs -n test-scheduler <pod-name>
```
* Componentes del Control Plane
```bash
# Logs del API Server
kubectl logs -n kube-system kube-apiserver-kind-control-plane

# Logs del Controller Manager
kubectl logs -n kube-system kube-controller-manager-kind-control-plane

# Logs del Scheduler por defecto
kubectl logs -n kube-system kube-scheduler-kind-control-plane

# Verificar salud de etcd
kubectl get endpoints -n kube-system etcd -o yaml
```
### Consejos de Uso

* Para problemas de scheduling, empezar con: 
```Bash
kubectl get events -n test-scheduler
```
* Para verificar el scheduler personalizado: 
```Bash
kubectl logs -n kube-system -l app=my-scheduler
```
* Para pods pendientes:
```Bash 
 kubectl get pods -n test-scheduler --field-selector=status.phase=Pending
```
