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

Noa II: Una vez modificamos el manifiesto y lanzamos el scheduler con la versión nueva, nos encontramos con un error:
```Bash
        jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl -n kube-system logs -f my-scheduler-6fbbc9c795-7h7gz [polling] scheduler starting… name=my-scheduler error: Invalid value for `target`, must not be `None`
```

Hemos encontrado que el error aparece desde 2018 y quye hoy ern día no hay solución:

- [Errro client python API Kubernetes](https://github.com/kubernetes-client/python/issues/825)
- [StackOverflow sobre create_namespaced_binding](https://stackoverflow.com/questions/50729834/kubernetes-python-client-api-create-namespaced-binding-method-shows-target-nam?utm_source=chatgpt.com)
  
En Python, usando el cliente oficial (`kubernetes.client`), se hace así:

1. Se crea un **V1ObjectReference** que apunta al nodo destino.
2. Se crea un **V1ObjectMeta** con el nombre y namespace del Pod.
3. Se crea un **V1Binding** combinando el target y los metadatos.
4. Se llama a **`create_namespaced_pod_binding()`** para enviar el binding al API server. O seguir utilizando
   **`create_namespaced_binding()`** pero añadiendo el parámetro `_preload_content=False` para evbitar serializar el objeto y que salkete la excepción del error.

La función nos queda:

```python
def bind_pod(api: client.CoreV1Api, pod, node_name: str):
    try:
        target = client.V1ObjectReference(kind="Node", name=node_name)
        meta = client.V1ObjectMeta(name=pod.metadata.name)
        body = client.V1Binding(target=target, metadata=meta)
        api.create_namespaced_binding(pod.metadata.namespace, body, _preload_cont>
    except Exception as e:
        import traceback
        traceback.print_exc()
        print("ERROR DETALLADO:", repr(e))

```

**Modificamos** el código del **scheduler polling** para generar el binding del Pod y asignarle un nodo de ejecución usando el parámetro que evita la serialización del evento de asignación y por tanto la excepción. Tras aplicar la modificación, borramos los Pods existentes y la imagen cargada, para poder reconstruirla y ejecutar todo nuevamente desde cero.

1. Borrar la imagen local:
```Bash
docker rmi my-py-scheduler:latest
```

2. Borrar la imagen dentro del nodo Kind:
```Bash
docker exec -it sched-lab-control-plane crictl rmi my-py-scheduler:latest
```

3. (Opcional) Borrar la imagen en nodos worker si existieran:
```Bash
docker exec -it sched-lab-worker crictl rmi my-py-scheduler:latest
```

4. Construirla de nuevo:
```Bash
docker build --no-cache -t my-py-scheduler:latest .
```

5. Cargarla otra vez en Kind:
```Bash
kind load docker-image my-py-scheduler:latest --name sched-lab
```

6. Borramos my-scheluder y test-pod:
```Bash
kubectl delete deployment my-scheduler -n kube-system
```
```Bash
kubectl delete pod test-pod
```
7. Hacemos el deploy nuevamente del scheduler modificado:
```Bash
kubectl apply -f rbac-deploy.yaml
```

8. Hacemos el deploy de Test_pod:
```Bash
kubectl apply -f test-pod.yaml
```

9. Comprobamos los logs que no hayan nuevos errores:
```Bash
kubectl -n kube-system logs -f deploy/my-scheduler
```

Después de realizar algunas pruebas, observé que el Pod sí se asigna a un nodo:

```bash
kubectl -n test-scheduler get pod test-pod -w

NAME       READY   STATUS             RESTARTS   AGE
test-pod   0/1     Pending            0          0s
test-pod   0/1     ContainerCreating  0          0s
test-pod   1/1     Running            0          3s
```

Al revisar los eventos en el namespace donde se encuentra el Pod y los logs de my-scheduler, podemos confirmar que es nuestro scheduler personalizado (my-scheduler) quien asignó el nodo al Pod.

```bash
kubectl -n test-scheduler get events --field-selector involvedObject.name=test-pod --sort-by='.metadata.creationTimestamp'

LAST SEEN   TYPE     REASON    OBJECT         MESSAGE
53s         Normal   Pulled    pod/test-pod   Container image "registry.k8s.io/pause:3.9" already present on machine
53s         Normal   Created   pod/test-pod   Created container pause
53s         Normal   Started   pod/test-pod   Started container pause
```
Y:

```bash
kubectl -n kube-system logs -f my-scheduler-6fbbc9c795-pfxw9

[polling] scheduler starting… name=my-scheduler
Bound test-scheduler/test-pod -> sched-lab-control-plane
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

**Otra alternativa más segura es crear un namespace de prueba dedicado (`test-scheduler`) y dar permisos a nuestro scheduler (`my-scheduler`) únicamente sobre ese namespace.** Esto nos permite mantener el namespace `default` intacto y limitar el alcance de los permisos, reduciendo riesgos de seguridad.

**Ventajas:**  
- Limitamos los permisos de `my-scheduler` solo al namespace de prueba (`test-scheduler`).  
- Evitamos manipular Pods críticos en `default`.  
- Mantenemos un entorno controlado para probar y depurar nuestro scheduler.

El hecho de tener que dar a `my-scheduler` permisos para trabajar con los Pods presentes en el namespace `default` serían:

- `my-scheduler` se ejecuta en el namespace `kube-system` con acceso al API del cluster. Si le otorgamos permisos sobre `default`, podría modificar cualquier Pod existente allí.  
- Esto implica que un atacante que comprometa nuestro scheduler podría alterar Pods críticos del sistema o de otras aplicaciones, provocando fallos, reinicios o acceso no autorizado a datos.  
- Por eso es más seguro crear un namespace de pruebas (`test-scheduler`) y limitar los permisos del scheduler únicamente a ese namespace, evitando riesgos innecesarios.  - Además, debemos asegurarnos de no sobreescribir roles críticos ni dar permisos más amplios de los estrictamente necesarios.

En este caso, con el nuevo namespace `test-scheduler`, modificamos el manifiesto `test-pod.yaml` y el manifiesto `rbac-deploy.yaml`, el cual es el que asigna los roles (permisos) a `my-scheduler`:

**Manifiesto test-pod.yaml modificado qued:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: test-scheduler
spec:
  schedulerName: my-scheduler
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
```

**Manifiesto RBAC modificado para permitir acceso a Pods en `test-scheduler`:** . De esta manera tenemos Role(permisos) tanto para `kube-system` cómo para ´test-scheduler`. Permisos tanto para los namespaces como para el clúster. 

```yaml
# ServiceAccount en kube-system
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-scheduler
  namespace: kube-system
---
# ClusterRole con permisos COMPLETOS del scheduler
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: my-scheduler-clusterrole
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "delete"]
- apiGroups: [""]
  resources: ["pods/binding"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
---
# ClusterRoleBinding que une ClusterRole y ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-scheduler-clusterrolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: my-scheduler-clusterrole
subjects:
- kind: ServiceAccount
  name: my-scheduler
  namespace: kube-system
---
# 🔥 NUEVO: Role para kube-system
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: my-scheduler-role-kube-system
  namespace: kube-system  # ✅ Para kube-system
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "patch", "update"]
---
# 🔥 NUEVO: RoleBinding para kube-system
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: my-scheduler-rolebinding-kube-system
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: my-scheduler-role-kube-system
subjects:
- kind: ServiceAccount
  name: my-scheduler
  namespace: kube-system
---
# Role para test-scheduler (el que ya tenías)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: my-scheduler-role-test
  namespace: test-scheduler
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "patch", "update"]
---
# RoleBinding para test-scheduler (el que ya tenías)
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: my-scheduler-rolebinding-test
  namespace: test-scheduler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: my-scheduler-role-test
subjects:
- kind: ServiceAccount
  name: my-scheduler
  namespace: kube-system
---
# Deployment del scheduler
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-scheduler
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-scheduler
  template:
    metadata:
      labels:
        app: my-scheduler
    spec:
      serviceAccountName: my-scheduler
      containers:
      - name: scheduler
        image: my-py-scheduler:latest
        imagePullPolicy: Never
        args: ["--scheduler-name", "my-scheduler"]

```

Una vez modificado el manifiesto del Pod, creamos el nuevo namespace con  `kubectl create namespace test-scheduler`. Y ejecutamos `los pasos del 1 al 9` teniendo en cuenta el nuevo namespace para el pod 'test-pod'. Al finalizar todos los pasos comprobamos que el scheduler personalizado (`my_scheduler`) se ejecuta correctamente y asigna un nodo al Pod creado, sin generar errores de permisos.

1. Borrar la imagen local:
```Bash
docker rmi my-py-scheduler:latest
```

2. Borrar la imagen dentro del nodo Kind:
```Bash
docker exec -it sched-lab-control-plane crictl rmi my-py-scheduler:latest
```

3. (Opcional) Borrar la imagen en nodos worker si existieran:
```Bash
docker exec -it sched-lab-worker crictl rmi my-py-scheduler:latest
```

4. Construirla de nuevo:
```Bash
docker build --no-cache -t my-py-scheduler:latest .
```

5. Cargarla otra vez en Kind:
```Bash
kind load docker-image my-py-scheduler:latest --name sched-lab
```

6. Borramos my-scheluder y test-pod:
```Bash
kubectl delete deployment my-scheduler -n kube-system
```
```Bash
kubectl delete pod test-pod -n test-scheduler
```
7. Hacemos el deploy nuevamente del scheduler modificado:
```Bash
kubectl apply -f rbac-deploy.yaml
```

8. Hacemos el deploy de Test_pod:
```Bash
kubectl apply -f test-pod.yaml -n test-scheduler
```

9. Comprobamos los logs que no hayan nuevos errores:
```Bash
kubectl -n kube-system logs -f deploy/my-scheduler
```

**f) Métricas:** Para comrpbar la latencia y la carga generada por `my_scheduler`, en su versión `polling`, lanzamos estos comandos:

f-1) Comprobar latencia

```Bash
kubectl -n kube-system logs -l app=my-scheduler --timestamps
```

- Tiempo t0: momento en que ejecutamos `kubectl run`

- Tiempo t1: primera línea del log donde el scheduler muestra que ha detectado un Pod pendiente (aparece "Detected Pending Pod").

- Latencia --> Δt = t1 – t0
- 
Entonces:

```Bash
 date -u +"%H:%M:%S.%3N"
23:23:34.352

kubectl apply -f test-pod.yaml -n test-scheduler

kubectl -n kube-system logs -l app=my-scheduler --timestamps
2025-11-08T23:23:15.656585227Z [polling] scheduler starting… name=my-scheduler
2025-11-08T23:24:31.802015916Z Bound test-scheduler/test-pod -> sched-lab-control-plane


t0 = 23:23:34.352
t1 = 2025-11-08T23:24:31.802015916Z = 23:24:31.802

# Calculamos la diferencia:

- Minutos: 24 – 23 = 1 minuto
- Segundos:  31.802 – 34.352 = -2.550 segundos → hay que restar 1 minuto y sumar 60 segundos → 57.450 segundos

Total Δt = 57.450 segundos
```
✅ Por lo tanto, la **latencia aproximada** es **57.450 segundos.** (hay que tneer en cuenta que se ha lanzado de forma manual en shell y eso retarda bastante. Mediante un script dicha latencia será menor)
 
f-2) Comprobar carga

1.Medir las peticiones generadas hacia el API Server:

Primero, identificamos el pod del API Server en Kind:

```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl -n kube-system get pods | grep apiserver
kube-apiserver-sched-lab-control-plane            1/1     Running   0             43m
```

y luego calculamos el número de operaciones LIST que ha recibido el API Server:

```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl -n kube-system logs kube-apiserver-sched-lab-control-plane | grep LIST | wc -l
2
```
Por tanto **la carca** que genera el scheduler **(`my-scheduler`)** es **2** (cuántas veces el scheduler hizo un Bound al pod en sus logs).

2.Medir consumo del Pod del scheduler:

```Bash
kubectl top pod -n kube-system | grep my-scheduler
```
Para poder usar `kubectl top` y ver el `consumo de CPU` y `memoria` del `Pod my-scheduler`, es necesario que el clúster tenga `habilitado` el `metrics-server`, ya que este servicio recopila y expone las métricas de los pods.

Pasos:

a) Instalar metrics-server (en Kind, si aún no está):

```Bash
curl -LO https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```
Añadimos el flag `--kubelet-insecure-tls` al container para que confie en lso certificados dentro de kind:

```Bash
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```
b) Esperar unos minutos a que el metrics-server se despliegue y esté listo:
```Bash
kubectl get pods -n kube-system | grep metrics-server
```

c) Una vez activo, se puede consultar el consumo de my-scheduler con:
```Bash
kubectl top pod -n kube-system | grep my-scheduler

```
Aplicando el comando anterior nos da:
```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler$ kubectl top pod -n kube-system | grep my-scheduler
my-scheduler-6fbbc9c795-pfxw9                     1m           59Mi
```
Eso significa que `my-scheduler` está usando actualmente:

- CPU: 1m → 1 millicore, es decir, aproximadamente el 0,1 % de un núcleo de CPU del nodo.

- Memoria: 59Mi → 59 MiB de memoria RAM consumida

Notar que es poco porque sólo hemos utilizado el pod `test_pod`. En cualquier caso el objetivo es comprobar que nuestro scheduler personalizao funciona dentro del cluster y asigna el nodo a los pods que le asignmamos.
  
f-3) Medir eficiencia del flujo del scheduling con un único Pod

Aunque solo haya un Pod, puede medir cómo cambia la “pipeline de scheduling” entre polling y watch. Vamos a crear ahora un Pod con un servbidor nginx.
 
  a) Cargamos la imagen de Nginx en tu cluster KIND. Como el clúster no tiene acceso directo a internet para descargar imágenes, primero traemos la imagen y la cargamos en KIND:
  
```Bash
docker pull nginx:latest
kind load docker-image nginx:latest --name sched-lab
```
  b) Creamos el manifiesto del Pod, indicando explícitamente que use tu scheduler personalizado (my-scheduler) y que ejecute Nginx:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test
  namespace: test-scheduler
spec:
  containers:
  - name: nginx
    image: nginx
  schedulerName: my-scheduler
  restartPolicy: Never
```
 c) Lanzamos el Pod de prueba asociado al servidor nginx:
 
```Bash
kubectl apply -f test_nginx_pod.yaml
```
- Obtenemos eventos:
```Bash
kubectl get events -n test-scheduler --sort-by=.metadata.creationTimestamp
```

d) Revisamos:

* Número de logs redundantes del scheduler polling: Cuántas veces el scheduler polling imprime “Pending”.

```Bash
kubectl -n test-scheduler get pod test -o custom-olumns=TIME:.metadata.creationTimestamp,STATUS:.status.phase -w
```
```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler$ kubectl -n test-scheduler get pod test -o custom-columns=TIME:.metadata.creationTimestamp,STATUS:.status.phase -w
TIME                   STATUS
2025-11-08T21:04:46Z   Running
2025-11-08T21:04:46Z   Running
2025-11-08T21:04:46Z   Succeeded
2025-11-08T21:04:46Z   Succeeded
2025-11-08T21:04:46Z   Succeeded
2025-11-08T21:04:46Z   Succeeded
2025-11-08T21:06:53Z   Pending
2025-11-08T21:06:53Z   Pending
2025-11-08T21:06:53Z   Pending
2025-11-08T21:06:53Z   Running
```
* Cambios de estado Pending → Running:
  
```Bash
creation=$(kubectl -n test-scheduler get pod test -o jsonpath='{.metadata.creationTimestamp}')
start=$(kubectl -n test-scheduler get pod test -o jsonpath='{.status.startTime}')
echo "Tiempo total en segundos: $(( $(date -d "$start" +%s) - $(date -d "$creation" +%s) ))"
```

- Antes: Pending
- Después: Running
- Tiempo total = Scheduling + Container start.

 **El resultado son : Tiempo total en segundos: 4**


Tambiém podemos verlo con los eventos que genera `my-scheduler` :

```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl get events -n test-scheduler --field-selector involvedObject.name=test --sort-by=.metadata.creationTimestamp
LAST SEEN   TYPE     REASON    OBJECT     MESSAGE
11m         Normal   Pulling   pod/test   Pulling image "nginx"
11m         Normal   Pulled    pod/test   Successfully pulled image "nginx" in 943ms (943ms including waiting). Image size: 59774010 bytes.
11m         Normal   Created   pod/test   Created container nginx
11m         Normal   Started   pod/test   Started container nginx
5m47s       Normal   Killing   pod/test   Stopping container nginx
5m33s       Normal   Pulling   pod/test   Pulling image "nginx"
5m32s       Normal   Pulled    pod/test   Successfully pulled image "nginx" in 944ms (944ms including waiting). Image size: 59774010 bytes.
5m32s       Normal   Created   pod/test   Created container nginx
5m32s       Normal   Started   pod/test   Started container nginx
3m36s       Normal   Killing   pod/test   Stopping container nginx
3m25s       Normal   Pulling   pod/test   Pulling image "nginx"
3m24s       Normal   Pulled    pod/test   Successfully pulled image "nginx" in 947ms (947ms including waiting). Image size: 59774010 bytes.
3m24s       Normal   Created   pod/test   Created container nginx
3m24s       Normal   Started   pod/test   Started container nginx
```
Para obtenr la latencia de `my-scheduler` desde que detecta el Pod de nginx (`Pulling`) hasta que el Pod cambia a `Started`:

```Bash
kubectl get events -n test-scheduler --field-selector involvedObject.name=test --sort-by=.metadata.creationTimestamp \
-o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{"\n"}{end}' | grep -E 'Pulling|Started' | awk '
/Pulling/ {pull=$1; pull_time=$2}
/Started/ {start=$1; start_time=$2; print "Interval: " pull " -> " start ", duration approx: " (mktime(gensub(/[-:T]/," ","g",start))-mktime(gensub(/[-:T]/," ","g",pull))) "s"}'
```
El resultado de aplicar el comadno es:

```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl get events -n test-scheduler --field-selector involvedObject.name=test --sort-by=.metadata.creationTimestamp \
-o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{"\n"}{end}' | grep -E 'Pulling|Started' | awk '
/Pulling/ {pull=$1; pull_time=$2}
/Started/ {start=$1; start_time=$2; print "Interval: " pull " -> " start ", duration approx: " (mktime(gensub(/[-:T]/," ","g",start))-mktime(gensub(/[-:T]/," ","g",pull))) "s"}'
Interval: 2025-11-08T20:58:49Z -> 2025-11-08T20:58:50Z, duration approx: 1s
Interval: 2025-11-08T21:04:49Z -> 2025-11-08T21:04:50Z, duration approx: 1s
Interval: 2025-11-08T21:06:57Z -> 2025-11-08T21:06:58Z, duration approx: 1s
```

### ✅**Checkpoint 3:**

***Your scheduler should log a message like:***
    - Bound default/test-pod -> kind-control-plane

En los pasos anteriores ya mostramos las capturas de pantalla y todos lso pasos realizados para el despliegue del scheduler personalizado (scheduler-polling) y la cpatura de las métricas. Para hacerlo automatizado creamos un script que permite crear el clsuter, lanzar el scheduler, los pods de pruebas y calcular las metricas de latencia y carga de nuestro scheduler. El script se meustra a continuación:

- ***`metrics-polling.sh`***
  
```Bash

```

Los resultados para este scheduler polling son:


## 🧩 Step 7 — Event-Driven Scheduler (Watch API)

En este paso modificamos `my_scheduler`del cluster para que se ejecute la versión `watch`. Realizamos todos los pasos anteriores para cargar la imagen con mi nuevo `scheduler_watch` y calcular las nuevas métricas.

Ahora ya no listamos todos lso Pod's que tenemos, sino que creamos un watch por cad auno y cuando nos llega el evento asociado al Pod ejecutamos una acción determinada. El código del nmuevo scheduler es el siguiente:

```Python
import argparse, math
from kubernetes import client, config, watch

import signal
import sys

# Flag global
running = True

# Handler para Ctrl+C o SIGTERM
def signal_handler(sig, frame):
    global running
    print("[info] Señal de terminación recibida, deteniendo scheduler...")
    running = False

signal.signal(signal.SIGINT, signal_handler)   # Ctrl+C
signal.signal(signal.SIGTERM, signal_handler)  # Kill desde Kubernetes

# TODO: load_client(kubeconfig) -> CoreV1Api
#  - Use config.load_incluster_config() by default, else config.load_kube_config()
def load_client(kubeconfig=None):
    """
    Carga la configuración de Kubernetes.
    Usa kubeconfig si se pasa como argumento,
    o las credenciales del Pod si se ejecuta dentro del clúster.
    """
    try:
        if kubeconfig:
            print("[config] Cargando configuración desde kubeconfig local...")
            config.load_kube_config(config_file=kubeconfig)
        else:
            print("[config] Cargando configuración dentro del clúster...")
            config.load_incluster_config()
    except Exception as e:
        raise RuntimeError(f"Error al cargar configuración: {e}")
    
    return client.CoreV1Api()
# TODO: bind_pod(api, pod, node_name)
#  - Create a V1Binding with metadata.name=pod.name and target.kind=Node,target.name=node_name
#  - Call api.create_namespaced_binding(namespace, body)
def bind_pod(api, pod, node_name):
    """
    Crea un binding entre el Pod y el nodo elegido.
    """
    target = client.V1ObjectReference(api_version="v1", kind="Node", name=node_name)
    metadata = client.V1ObjectMeta(name=pod.metadata.name)
    body = client.V1Binding(target=target, metadata=metadata)
    namespace = pod.metadata.namespace

    api.create_namespaced_binding(namespace=namespace, body=body)
    print(f"[bind] Pod {namespace}/{pod.metadata.name} -> {node_name}")
# TODO: choose_node(api, pod) -> str
#  - List nodes and pick one based on a simple policy (fewest running pods)
def choose_node(api, pod):
    """
    Selecciona el nodo con menos Pods asignados (política simple).
    """
    nodes = api.list_node().items
    pods = api.list_pod_for_all_namespaces().items
    node_load = {n.metadata.name: 0 for n in nodes}

    for p in pods:
        if p.spec.node_name:
            node_load[p.spec.node_name] += 1

    node = min(node_load, key=node_load.get)
    print(f"[policy] Nodo elegido para {pod.metadata.name}: {node}")
    return node
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scheduler-name", default="my-scheduler")
    parser.add_argument("--kubeconfig", default=None)
    args = parser.parse_args()

    # TODO: api = load_client(args.kubeconfig)

    print(f"[watch] scheduler starting… name={args.scheduler_name}")
    w = watch.Watch()
    # Stream Pod events across all namespaces
    print(f"[scheduler] Iniciando scheduler personalizado: {args.scheduler_name}")
    
    while running:
      try:
         for event in w.stream(api.list_pod_for_all_namespaces, timeout_seconds=60):
           if not running:
             break
           pod = event['object']
           if not pod or not hasattr(pod, 'spec'):
              continue
           if event['type'] not in ("ADDED", "MODIFIED"):
              continue
           if (pod.status.phase == "Pending" and
                pod.spec.scheduler_name == args.scheduler_name and
                not pod.spec.node_name):
              print(f"[event] Pod pendiente detectado: {pod.metadata.namespace}/{pod.metadata.name}")
              try:
                node = choose_node(api, pod)
                bind_pod(api, pod, node)
                print(f"[success] {pod.metadata.namespace}/{pod.metadata.name} -> {node}")
              except Exception as e:
                print(f"[error] Error al programar {pod.metadata.name}: {e}")
      except Exception as e:
         if running:
           print(f"[warn] Watch detenido de forma limpia.")

if __name__ == "__main__":
    main()
```
Cómo en el apartado anterior, hemos creado un script que carga ydespleiga el scheduler-watch y calcula las metriucas asociadas al procesamiento de los pods de prueba. El script es el siguiente:

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

Comparamos los valores obteneidos por lso scripts para cad auno de los tipos de scheduler para los mismnos Pods de prueba. En un principio tenemos que ver que los valores para el scheduler de tipo watch son mejroes que para el tipo polling. 



## 🧩 Step 8 — Policy Extensions

1. Label-based node filtering
```Bash
nodes = [n for n in api.list_node().items
if "env" in (n.metadata.labels or {}) and
n.metadata.labels["env"] == "prod"]
```

***Resolución:***
Actualmente elegimos el nodo con menos Pods. Podemos mejorar considerando el tipo de Pod o label de aplicación:
```python
def choose_node(api, pod):
    nodes = [n for n in api.list_node().items
             if n.metadata.labels and n.metadata.labels.get("env") == "prod"
             and is_node_compatible(n, pod)]

    if not nodes:
        raise RuntimeError("No hay nodos disponibles compatibles")

    pods = api.list_pod_for_all_namespaces().items
    node_load = {n.metadata.name: 0 for n in nodes}

    # Contar solo Pods del mismo tipo/app para distribuirlos
    pod_app_label = pod.metadata.labels.get("app") if pod.metadata.labels else None
    for p in pods:
        if p.spec.node_name in node_load:
            if not pod_app_label or (p.metadata.labels and p.metadata.labels.get("app") == pod_app_label):
                node_load[p.spec.node_name] += 1

    node = min(node_load, key=node_load.get)
    print(f"[policy] Nodo elegido para {pod.metadata.name}: {node}")
    return node
```
Pero ademñas debemos modificar los manifiestos de lso pods para que tengan los labels por los cuales se deben filtar. 

- Para filtrar nodos por env=prod o para la política de spread (app=<nombre>), el Pod debe tener labels:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: test-scheduler
  labels:
    app: my-app    # Para la política de spread
    env: prod      # Para filtrar nodos por entorno
spec:
  schedulerName: my-scheduler
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
```
--1232-- HAy que modificarlo y probar, sacar imagenes del filtrado o logs 

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

