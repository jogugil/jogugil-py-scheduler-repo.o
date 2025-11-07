# Lab: Building a Custom Kubernetes Scheduler in Python
##  Learning Objectives
 * By the end of this lab, you will:
    - Understand how the **scheduler** interacts with the **API Server**.
    - Implement a **custom scheduler** that:
    - Finds **Pending Pods** with a given `schedulerName`.
    - Chooses a **Node** according to a scheduling policy.
    - **Binds** the Pod to that Node through the Kubernetes API.
    - Compare **polling vs event-driven (watch)** models.
    - Deploy your scheduler into a **kind cluster** and observe its behavior.

  ---

# Realización de la práctica:
 ## 🧰 Step 0 — Set up the environment
 
 We set up the environment using the required installation prerequisites. We then followed the steps described in 
 section `A` of the `README.md`.

 In the environment we prepared, we executed the first step:
 
 ## ⚙ Step 1 — Observe the Default Scheduler-. 
 
 1. Identify the running scheduler
```Bash
kubectl -n kube-system get pods -l component=kube-scheduler
kubectl -n kube-system logs -l component=kube-scheduler
```
 2.  Schedule a simple pod:
```Bash
kubectl run test --image=nginx --restart=Never
kubectl get pods -o wide
```

### ✅**Checkpoint 1:**
Describe the path:
    kubectl run → Pod created → Scheduler assigns Node → kubelet starts Pod.
 
<p align="center">
<img src="https://github.com/jogugil/jogugil-py-scheduler-repo.o/blob/main/img/fugura1-1.png" width="850">
  <br>
  <em>Figure 1: Verification of the default scheduler and scheduling of a test Pod.</em>
</p>

✅ **Descripción del flujo de scheduling en Kubernetes**

La **Figura 1** muestra la ejecución de los comandos utilizados para verificar que el scheduler por defecto está en funcionamiento y para observar cómo se programa un Pod sencillo dentro del clúster creado con Kind. A partir de los resultados obtenidos, podemos describir el funcionamiento interno del sistema cuando programamos un Pod:

**a) Enviamos la orden de creación del Pod**  
Ejecutamos `kubectl run test --image=nginx --restart=Never`, lo que provoca que el cliente `kubectl` envíe al API Server un objeto Pod para ser creado. En este momento, el Pod se registra pero aún no tiene un nodo asignado.

**b) El Pod queda inicialmente en estado *Pending***  
Tras su creación, el API Server almacena el Pod con `status=Pending`, ya que todavía no ha sido asociado a ningún nodo del clúster.

**c) El scheduler detecta el nuevo Pod sin asignar**  
El `kube-scheduler`, que aparece ejecutándose como se muestra en la Figura 1, observa periódicamente los Pods pendientes mediante sus mecanismos internos de *informers*.  
Detecta que el Pod recién creado no tiene un nodo asociado (`.spec.nodeName` vacío).

**d) El scheduler selecciona un nodo adecuado**  
Una vez detectado el Pod pendiente, el scheduler evalúa los nodos disponibles.  
En nuestro entorno Kind, la asignación habitual es al nodo de control (`sched-lab-control-plane`).  
El scheduler realiza entonces el *binding* del Pod, actualizando su campo `.spec.nodeName`.

**e) El kubelet del nodo asignado inicia el contenedor**  
Tras el binding, el kubelet del nodo seleccionado recibe la nueva especificación, descarga la imagen `nginx` si no está disponible y comienza a crear el contenedor.  
El estado del Pod pasa a `ContainerCreating` y finalmente a `Running`.

En conjunto, estos pasos confirman que el flujo interno es el esperado:

**kubectl run → API Server crea el Pod → Scheduler asigna nodo → Kubelet ejecuta el contenedor**,  
tal como se observa en la secuencia mostrada en **Figura 2**.



 ## 🧱 Step 2 — Project Setup

 Initialize Project
 
 ```Bash
mkdir py-scheduler && cd py-scheduler
python -m venv .venv && source .venv/bin/activate
pip install kubernetes==29.0.0
touch scheduler.py
 ```
Directory Structure

 ```Bash
py-scheduler/
├── scheduler.py
├── Dockerfile
├── rbac-deploy.yaml
├── test-pod.yaml
└── requirements.txt
 ```

<p align="center">
<img src="https://github.com/jogugil/jogugil-py-scheduler-repo.o/blob/main/img/Figura2.png" width="850">
  <br>
  <em>Figure 2: We create the local directory containing the files required to deploy the polling scheduler.</em>

</p>

## 🧠 Step 3 — Implement the Polling Scheduler
### ✅**Checkpoint 2:**

***Understand the control loop:***
    - **Observe**: *list unscheduled Pods:*    
    - **Decide**: *pick a Node*       
    - **Act**: *bind the Pod*

Para implementar el scheduler basado en *polling*, se ha seguido el patrón clásico de los controladores de Kubernetes: **Observar → Decidir → Actuar**. El código proporcionado ([variants/polling/scheduler.py](https://github.com/jogugil/jogugil-py-scheduler-repo.o/blob/main/variants/polling/scheduler.py)
) implementa este ciclo mediante consultas periódicas al API Server. A continuación describimos cada fase y su relación directa con el código del scheduler.

---

✅ **1. Observar: listar los Pods no programados**

En el bucle principal, el scheduler consulta periódicamente al API Server para obtener los Pods que cumplen:

- **no tienen nodo asignado**, es decir, están en estado `Pending` (`spec.nodeName=`), y  
- **solicitan explícitamente el scheduler personalizado** (`spec.schedulerName == args.scheduler_name`) (Debe ser `my_scheduler`).

```python
pods = api.list_pod_for_all_namespaces(
    field_selector="spec.nodeName="
).items

for pod in pods:
    if pod.spec.scheduler_name != args.scheduler_name:
        continue
```
  Así, sólo cogemos los Pods pendientes de asignación, es decir, que aún no tienen un nodo asignado (spec.nodeName vacío), lo que normalmente corresponde a Pods en estado Pending.
  
 ✅ 2. Decidir: seleccionar un nodo
La lógica de decisión está en:
 ```python
node = choose_node(api, pod)
 ```
La función `choose_node()` realiza lo siguiente:

a) Obtiene la lista completa de nodos: `nodes = api.list_node().items`  
b) Cuenta cuántos Pods están ya asignados a cada nodo: `cnt = sum(1 for p in pods if p.spec.node_name == n.metadata.name)`  
c) Selecciona el nodo con menos Pods, aplicando así una estrategia sencilla de “menor carga”: `if cnt < min_cnt:`  
 
   ✅ 3. Actuar: realizar el binding del Podç
    ```python
   bind_pod(api, pod, node_name)
    ```
El binding consiste en:
    a) crear una referencia al nodo: `target = client.V1ObjectReference(kind="Node", name=node_name)`
    b) crear la estructura V1Binding: `body = client.V1Binding(target=target, metadata=client.V1ObjectMeta(name=pod.metadata.name))`
    c) enviarla al API Server para completar la asignación: `api.create_namespaced_binding(pod.metadata.namespace, body)`

Este paso actualiza el campo .spec.nodeName del Pod.  Y a partir de aquí, el kubelet del nodo asignado detecta la nueva asignación y comienza la creación del contenedor correspondiente.
    
## 🐳🔐🧪 Step 4, 5 y 6 — Build and Deploy. RBAC & Deployment. Test Your Scheduler (polling)

Los pasos que hemos realizado para probar el `scheduler_polling` personalizado dentro del clúster son:

**a) Build:** Construimos nuestra imagen Docker etiquetándola como `latest` a partir del directorio actual. Esta imagen servirá como base para nuestras ejecuciones.

```Bash
docker build -t my-py-scheduler:latest .
```

**b) Load Image:** Cargamos esa imagen en el clúster Kind llamado `sched-lab` para poder usarla en nuestros despliegues.

```Bash
kind load docker-image my-py-scheduler:latest --name sched-lab
```

**c) RBAC:** Aplicamos las reglas RBAC que autorizan a nuestro scheduler a autenticarse y operar contra el API Server con los permisos definidos (roles del scheduler). Además, desplegamos nuestro scheduler (`my_scheduler`) en el cluster (`Control Plane`).

```Bash
kubectl apply -f rbac-deploy.yaml
```

d) API Server: Consultamos al API Server para obtener el listado de Pods con la etiqueta app=my-scheduler y verificar que nuestro scheduler se ha desplegado correctamente.

```Bash
kubectl -n kube-system get pods -l app=my-scheduler
```

Nota: Hemos **encontrado un error** al realizar los pasos `c` y `d`. Esto nos pasa porque en el manifiesto `rbac-deploy.yaml` no contiene una política de pull. Entonces Kubernetes aplica su política por defecto (`imagePullPolicy = Always`). Y marca el Pod como `ImagePullBackOff`. Por tanto, añadimos una política de Pull en el manifiesto (`imagePullPolicy: Never`):

```yaml
containers:
- name: scheduler
  image: my-py-scheduler:latest
  imagePullPolicy: Never
  args: ["--scheduler-name","my-scheduler"]
```

Podenmos poner:

- `imagePullPolicy: Never`: Para desarrollo local con Kind; asegura que Kubernetes solo usa la imagen local.

- `imagePullPolicy: IfNotPresent`: Si la imagen está en el nodo, la usa. Si no, intenta descargarla. Adecuado para despliegues mixtos.
  
- `imagePullPolicy: Always`: Fuerza siempre el pull y hace fallar imágenes locales.

¿Por qué ponemos `Never`?

Utilizamos esa política ya que estamos trabajando con una imagen local creada a mano y cargada con:

```Bash
kind load docker-image my-py-scheduler:latest --name sched-lab
```
Esto hace que la imagen esté disponible solo dentro de los nodos del clúster Kind, pero NO existe en Docker Hub ni en ningún registry remoto.

Por tanto:

Si Kubernetes intenta descargarla → fallará (ImagePullBackOff)

Si Kubernetes usa la imagen local → funcionará

Y para obligar a Kubernetes a usar la imagen local del nodo, la política exacta es:

  Volvemos a ejecutar el deployment:

```Bash
  kubectl -n kube-system delete pod -l app=my-scheduler
  kubectl apply -f rbac-deploy.yaml
  kubectl -n kube-system get pods -l app=my-scheduler
```

**e) Test Pod:** Creamos un Pod de prueba y lo desplegamos en el clúster para comprobar que nuestro scheduler (`my_scheduler`) obtiene el Pod creado y le asigna un nodo.

```Bash
kubectl apply -f test-pod.yaml
kubectl get pods -o wide
kubectl -n kube-system logs deploy/my-scheduler
```

Noa II: Una vez modificado el manifiesto y lanzado el scheduler con el nuevo, nos encontramos con un nuevo error:

        jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl -n kube-system logs -f my-scheduler-6fbbc9c795-7h7gz [polling] scheduler starting… name=my-scheduler error: Invalid value for `target`, must not be `None`

Hemops encontrado que el API se ha modificado y debemos cambiar el codigo python:

https://stackoverflow.com/questions/50729834/kubernetes-python-client-api-create-namespaced-binding-method-shows-target-nam?utm_source=chatgpt.com


En el nuevo API : https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.30/#binding-v1-core

La forma correcta de asignar un Pod es mediante:

PATCH /api/v1/namespaces/{namespace}/pods/{name}
spec.nodeName = <node>


que en Python es exactamente:


```python
api.patch_namespaced_pod(
    name=pod.metadata.name,
    namespace=pod.metadata.namespace,
    body={"spec": {"nodeName": node_name}}
)
```

por tanto, la nueva función quedará:

```python
def bind_pod(api, pod, node_name):
    patch = {"spec": {"nodeName": node_name}}
    api.patch_namespaced_pod(
        name=pod.metadata.name,
        namespace=pod.metadata.namespace,
        body=patch
    )
```

**Modificamos** el código del **scheduler polling** para generar el binding del Pod y asignarle un nodo de ejecución usando la nueva versión del API (patch directo del `nodeName` en lugar de `create_namespaced_binding`). Tras aplicar la modificación, borramos los Pods existentes y la imagen cargada, para poder reconstruirla y ejecutar todo nuevamente desde cero.

1. Borrar la imagen local:
```Bash
docker rmi my-py-scheduler:latest
```

3. Borrar la imagen dentro del nodo Kind:
```Bash
docker exec -it sched-lab-control-plane crictl rmi my-py-scheduler:latest
```

4. (Opcional) Borrar la imagen en nodos worker si existieran:
```Bash
docker exec -it sched-lab-worker crictl rmi my-py-scheduler:latest
```

5. Construirla de nuevo:
```Bash
docker build -t my-py-scheduler:latest .
```

6. Cargarla otra vez en Kind:
```Bash
kind load docker-image my-py-scheduler:latest --name sched-lab
```

7. Borramos test_pod:
```Bash
kubectl delete pod test-pod
```

9. Hacemos el deploy nuevamente del scheduler modificado:
```Bash
kubectl apply -f rbac-deploy.yaml
```

10. Hacemos el deploy de Test_pod:
```Bash
kubectl apply -f test-pod.yaml
```

11. Comprobamos los logs que no hayan nuevos errores:
```Bash
kubectl -n kube-system logs -f deploy/my-scheduler
```

**Nota III: Nuevo error: Al ejecutar el scheduler modificado sobre test_POD**

Modificamos el código Python del scheduler y ya vemos que se está ejecutando. Sin embargo, aparece un nuevo error porque no tenemos permisos para trabajar con Pods en el namespace `default`. Por tanto, tendremos que ajustar el manifiesto del Pod o los permisos del ServiceAccount.

```bash
# Comprobamos que nuestro scheduler está corriendo
kubectl -n kube-system get pods -l app=my-scheduler
NAME                            READY   STATUS    RESTARTS   AGE
my-scheduler-6fbbc9c795-4drdb   1/1     Running   0          4m36s

# Revisamos los logs del scheduler
kubectl -n kube-system logs -f deploy/my-scheduler
[polling] scheduler starting… name=my-scheduler
[TRACE] bind_pod called for kube-system/test-pod -> sched-lab-control-plane

# Creamos el Pod de prueba
kubectl apply -f test-pod.yaml
pod/test-pod created

# Volvemos a revisar los logs del scheduler
kubectl -n kube-system logs -f deploy/my-scheduler
[TRACE] bind_pod called for default/test-pod -> sched-lab-control-plane
Traceback (most recent call last):
  File "/app/scheduler.py", line 27, in bind_pod
    api.patch_namespaced_pod(
kubernetes.client.exceptions.ApiException: (403)
Reason: Forbidden
HTTP response body: {"message":"pods \"test-pod\" is forbidden: User \"system:serviceaccount:kube-system:my-scheduler\" cannot patch resource \"pods\" in API group \"\" in the namespace \"default\""}
```
El nuevo error se debe a que el ServiceAccount `my-scheduler` no tiene permisos RBAC para modificar Pods en el namespace `default`. Para solucionarlo, modificamos el manifiesto de `test-pod.yaml` para que se cree en `kube-system`, donde sí tenemos permisos, de la siguiente manera:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: kube-system
spec:
  schedulerName: my-scheduler
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
```

**Otra alternativa más elegante sería modificar el manifiesto RBAC para que nuestro scheduler (`my-scheduler`) tenga permisos también sobre los Pods creados en el namespace `default`.** Esto permite mantener los Pods en `default` y que nuestro scheduler personalizado pueda asignar nodos sin necesidad de cambiar el namespace de los Pods.  

**Contras:**  
- Dar permisos al scheduler sobre `default` expone un riesgo de seguridad: cualquier Pod en `default` podría ser manipulado por `my-scheduler`.  
- Hay que asegurarse de no sobreescribir roles críticos ni dar más permisos de los estrictamente necesarios.  

**Manifiesto RBAC modificado para permitir acceso a Pods en `default`:**  

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-scheduler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: my-scheduler-role
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "patch", "update"]
# Esta sección es la que añadimos o modificamos para dar permisos a nuestro scheduler
# sobre los Pods en cualquier namespace (incluido 'default')
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-scheduler-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: my-scheduler-role
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
      containers:
      - name: scheduler
        image: my-py-scheduler:latest
        imagePullPolicy: Never
        args: ["--scheduler-name","my-scheduler"]
# Aquí no necesitamos cambiar nada; el scheduler seguirá usando el ServiceAccount con los permisos ampliados

Una vez modificado el manifiesto del Pod, ejecutamos `los pasos del 1 al 11` y comprobamos que el scheduler personalizado (`my_scheduler`) se ejecuta correctamente y asigna un nodo al Pod creado, sin generar errores de permisos.


**f) Métricas:** Para comrpbar la latencia y la carga generada por `my_scheduler`, en su versión `polling`, lanzamos estos comandos:

f-1) Comprobar latencia

```Bash
kubectl -n kube-system logs -l app=my-scheduler-polling --timestamps
```

- Tiempo t0: momento en que ejecutamos `kubectl run`

- Tiempo t1: primera línea del log donde el scheduler muestra que ha detectado un Pod pendiente (aparece "Detected Pending Pod").

- Latencia --> Δt = t1 – t0

f-2) Comprobar carga

1.Medir las peticiones generadas hacia el API Server:

```Bash
kubectl -n kube-system logs -l kube-apiserver | grep LIST | wc -l
```

2.Medir consumo del Pod del scheduler:
```Bash
kubectl top pod -n kube-system | grep my-scheduler
```

f-3) Medir eficiencia del flujo del scheduling con un único Pod

Aunque solo haya un Pod, puede medir cómo cambia la “pipeline de scheduling” entre polling y watch.
 
 
- Lanzamos un Pod sencillo:
```Bash
kubectl run test --image=nginx --restart=Never
```

- Obtenemos eventos:
```Bash
kubectl get events --sort-by=.metadata.creationTimestamp
```

- Revisamos:

* Número de logs redundantes del scheduler polling: Cuántas veces el scheduler polling imprime “No pending pods” o “Checking pending pods”.

```Bash
kubectl -n kube-system logs -l app=my-scheduler-polling | grep "Checking pending pods" | wc -l
```
* Cambios de estado Pending → Running:
```Bash
kubectl get pod test -o jsonpath='{.status.phase}'
```

- Antes: Pending

- Después: Running

- Tiempo total = Scheduling + Container start.

* Cuántas veces el scheduler polling detecta el Pod:

(para polling)
```Bash
kubectl -n kube-system logs -l app=my-scheduler-polling | grep "Detected Pending Pod" | wc -l
```

(para watch)

```Bash
kubectl -n kube-system logs -l app=my-scheduler-watch | grep "Pod added" | wc -l
```
  
### ✅**Checkpoint 3:**

***Your scheduler should log a message like:***
    - Bound default/test-pod -> kind-control-plane
    

## 🧩 Step 7 — Event-Driven Scheduler (Watch API)

En este paso modificamos `my_scheduler`del cluster para que se ejecute la versión `watch`. Realizamos todos los pasos anteriores para cargar la imagen con mi nuevo `scheduler_watch` y calcular las nuevas métricas.

Notar que para obtener las métricas de cada uno de los shceulers persoinalizamos hemos creado lso siguientes scripts.

- ***`metrics-polling.sh`***
```Bash
#!/bin/bash

SCHED_NS="kube-system"
SCHED_LABEL="app=my-scheduler-polling"
TEST_POD="test-metric-polling"

echo "======================================================="
echo " MÉTRICAS DEL SCHEDULER POLLING"
echo "======================================================="

echo "[1] Lanzamos Pod de prueba"
T0=$(date +%s%3N)
kubectl run $TEST_POD --image=nginx --restart=Never >/dev/null 2>&1

echo "[2] Esperamos a que se generen logs"
sleep 2

echo "[3] Obtenemos logs del scheduler polling"
kubectl -n $SCHED_NS logs -l $SCHED_LABEL --timestamps > polling.log

echo "[4] Calculamos latencia (t1 - t0)"
TS_LINE=$(grep -m1 "Detected Pending Pod" polling.log | awk '{print $1}')

if [[ -z "$TS_LINE" ]]; then
    echo "No se encontró 'Detected Pending Pod' en los logs del scheduler."
else
    # Convertir timestamp ISO8601 a epoch ms
    T1=$(date -d "$TS_LINE" +%s%3N)
    LATENCY=$((T1 - T0))
    echo "t0 (inicio): $T0 ms"
    echo "t1 (detección): $T1 ms"
    echo "Latencia total: $LATENCY ms"
fi

echo
echo "[5] Número de peticiones LIST al API Server"
LISTS=$(kubectl -n kube-system logs -l component=kube-apiserver | grep LIST | wc -l)
echo "Peticiones LIST: $LISTS"

echo
echo "[6] Consumo de CPU del scheduler polling"
kubectl top pod -n $SCHED_NS | grep my-scheduler-polling || echo "top no disponible"

echo
echo "[7] Eventos Kubernetes (Pending → Running)"
kubectl get events --sort-by=.metadata.creationTimestamp > events.log
grep $TEST_POD events.log

echo
echo "[8] Logs redundantes del polling"
REDUNDANT=$(grep -c "Checking pending pods" polling.log)
echo "Iteraciones del bucle polling: $REDUNDANT"

echo
echo "[9] Número de detecciones del Pod"
DETECTIONS=$(grep -c "Detected Pending Pod" polling.log)
echo "Detecciones totales: $DETECTIONS"

echo
echo "[10] Estado final del Pod"
STATE=$(kubectl get pod $TEST_POD -o jsonpath='{.status.phase}')
echo "Estado: $STATE"

echo
echo "[11] Limpieza del Pod de prueba"
kubectl delete pod $TEST_POD >/dev/null 2>&1
echo "Limpieza completada"

echo "======================================================="
echo " FIN DEL SCRIPT POLLING"
echo "======================================================="
```
- ***`metrics-watch.sh`***

```Bash
#!/bin/bash

SCHED_NS="kube-system"
SCHED_LABEL="app=my-scheduler-watch"
TEST_POD="test-metric-watch"

echo "======================================================="
echo " MÉTRICAS DEL SCHEDULER WATCH"
echo "======================================================="

echo "[1] Lanzamos Pod de prueba"
T0=$(date +%s%3N)
kubectl run $TEST_POD --image=nginx --restart=Never >/dev/null 2>&1

echo "[2] Esperamos a que se generen eventos"
sleep 1

echo "[3] Obtenemos logs del scheduler watch"
kubectl -n $SCHED_NS logs -l $SCHED_LABEL --timestamps > watch.log

echo "[4] Calculamos latencia (primer evento)"
TS_LINE=$(grep -m1 "Pod added" watch.log | awk '{print $1}')

if [[ -z "$TS_LINE" ]]; then
    echo "No se encontró 'Pod added' en los logs del scheduler watch."
else
    T1=$(date -d "$TS_LINE" +%s%3N)
    LATENCY=$((T1 - T0))
    echo "t0 (inicio): $T0 ms"
    echo "t1 (evento): $T1 ms"
    echo "Latencia total: $LATENCY ms"
fi

echo
echo "[5] Número de eventos Watch"
ADDED=$(grep -c "Pod added" watch.log)
UPDATED=$(grep -c "Pod updated" watch.log)
echo "Eventos 'Pod added': $ADDED"
echo "Eventos 'Pod updated': $UPDATED"

echo
echo "[6] Peticiones LIST al API Server"
LISTS=$(kubectl -n kube-system logs -l component=kube-apiserver | grep LIST | wc -l)
echo "Número de LIST: $LISTS"

echo
echo "[7] Consumo de CPU del scheduler watch"
kubectl top pod -n $SCHED_NS | grep my-scheduler-watch || echo "top no disponible"

echo
echo "[8] Eventos Kubernetes (Pending → Running)"
kubectl get events --sort-by=.metadata.creationTimestamp | grep $TEST_POD

echo
echo "[9] Estado final del Pod"
STATE=$(kubectl get pod $TEST_POD -o jsonpath='{.status.phase}')
echo "Estado: $STATE"

echo
echo "[10] Limpieza del Pod de prueba"
kubectl delete pod $TEST_POD >/dev/null 2>&1
echo "Limpieza completada"

echo "======================================================="
echo " FIN DEL SCRIPT WATCH"
echo "======================================================="
```

  


### ✅**Checkpoint 4:**
***Compare responsiveness and efficiency between polling and watch approaches.***

## 🧩 Step 8 — Policy Extensions

1. Label-based node filtering
```Bash
nodes = [n for n in api.list_node().items
if "env" in (n.metadata.labels or {}) and
n.metadata.labels["env"] == "prod"]
```
2. Taints and tolerations Use `node.spec.taints` and `pod.spec.tolerations` to filter nodes
before scoring.
3. Backoff / Retry Use exponential backoff when binding fails due to transient API errors.
4. Spread policy Distribute similar Pods evenly across Nodes.

### ✅ **Checkpoint 5:**
***Demonstrate your extended policy via pod logs and placement.***


# 🧠Reflection Discussion


- ***Why is it important that your scheduler writes a Binding object instead of patching a Pod directly?***
  
> ### Importancia de usar un `Binding` en lugar de modificar directamente un Pod
>
> Porque el uso de un `Binding` es el mecanismo definido por Kubernetes para asignar un Pod a un nodo.  
> En un principio, este mecanismo permite escalabilidad y fiabilidad del clúster, ya que comprueba si los nodos tienen permisos para ejecutar dicho Pod y si la carga del nodo permite ejecutarlo. Esto permite mantener un balance de carga y garantizar la seguridad en la ejecución de los contenedores.  
> La asignación se realiza de forma **atómica y segura**, es decir, o se asigna o no se asigna, evitando condiciones de carrera.  
> 
> Además, todo se realiza a través del **API Server**, lo que garantiza que el flujo de control sea el correcto dentro del sistema. Esto permite también mantener un sistema **auditable**, útil para depuración y trazabilidad.

- ***What are the trade-offs between polling vs event-driven models?***

> ### Ventajas y desventajas del modelo de polling
>
> **Ventajas:**
> - Muy fácil de implementar.  
> - No necesita controladores sofisticados.  
> - Tolera fallos temporales de conexión.
>
> **Desventajas:**
> - Introduce **latencia**: un Pod puede tardar en ser detectado.  
> - Genera **carga innecesaria** en el API Server por las consultas repetidas.  
> - No escala bien en clústeres grandes.
 
- ***How do taints and tolerations interact with your scheduling logic?***

> - Un **taint** en un nodo sirve para “repeler” Pods que no lo toleren.  
> - Una **toleration** en un Pod indica que puede ejecutarse en un nodo con ese taint.
>
> Para un scheduler personalizado:
> - a) Debemos **filtrar nodos cuyo taint no pueda ser tolerado** por el Pod.  
> - b) Si ignoramos esto, podríamos bindear un Pod a un nodo donde **nunca podrá ejecutarse**, quedando permanentemente en `Pending`.  
>
> **Ejemplo:**  
> Un Pod sin tolerations **no debe** ser programado en un nodo con el taint `NoSchedule`.
>
> Por tanto, un scheduler completo debe:
> - Leer los taints del nodo.  
> - Leer las tolerations del Pod.  
> - Excluir nodos incompatibles antes de tomar una decisión.
 
- ***What are real-world policies you could implement using this framework?***

> El framework permite implementar políticas reales como:
>
> - a) ***[Nodo menos cargado](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduler-perf-tuning/)*** (la que usamos).
>
> - b) ***[Resource Bin Packing](https://kubernetes.io/docs/concepts/scheduling-eviction/resource-bin-packing/)***: llenar nodos al máximo antes de usar nuevos.
>
> - c) ***[Affinity y Anti-affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#affinity-and-anti-affinity)***  
>     - Separar cargas sensibles.  
>     - Agrupar Pods que trabajan juntos.
>
> - d) ***Ahorro energético***  
>     - Consolidar cargas para apagar nodos poco usados.  
>     - Elegir nodos más eficientes.
>
> - e) ***Topología y rendimiento***  
>     - Elegir nodos según región, zona, latencia, GPU…  
>     - [Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)  
>     - [Node Labels](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#built-in-node-labels)  
>     - [Topology Manager / NUMA](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-manager/)
>
> - f) ***Prioridades y SLAs***  
>     - Colocar Pods prioritarios en nodos específicos.  
>     - [Pod Priority & Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)  
>     - [QoS Classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)

