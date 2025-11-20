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
  <em>Figure 1: Verification of the default scheduler and scheduling of a test-nginx-pod Pod.</em>
</p>

✅ **Descripción del flujo de scheduling en Kubernetes**

La **Figura 1** muestra la ejecución de los comandos utilizados para verificar que el scheduler por defecto está en funcionamiento y para observar cómo se programa un Pod sencillo dentro del clúster creado con Kind. A partir de los resultados obtenidos, podemos describir el funcionamiento interno del sistema cuando programamos un Pod:

**a) Enviamos la orden de creación del Pod**  
Ejecutamos `kubectl run test-nginx-pod --image=nginx --restart=Never`, lo que provoca que el cliente `kubectl` envíe al API Server un objeto Pod para ser creado. En este momento, el Pod se registra pero aún no tiene un nodo asignado.

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

Podemos poner:

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
        api.create_namespaced_binding(pod.metadata.namespace, body, _preload_content=False)
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

**Manifiesto RBAC  no hace falta modificarlo para permitir acceso a Pods en `test-scheduler`:** . De esta manera tenemos Role(permisos) tanto para `kube-system` cómo para ´test-scheduler`. Permisos tanto para los namespaces como para el clúster. 

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
      containers:
      - name: scheduler
        image: my-py-scheduler:latest
        imagePullPolicy: Never
        args: ["--scheduler-name","my-scheduler"]

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
  name: test-nginx-pod
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
kubectl -n test-scheduler get pod test-nginx-pod -o custom-columns=TIME:.metadata.creationTimestamp,STATUS:.status.phase -w
```
```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler$ kubectl -n test-scheduler get pod test-nginx-pod -o custom-columns=TIME:.metadata.creationTimestamp,STATUS:.status.phase -w
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
creation=$(kubectl -n test-scheduler get pod test-nginx-pod -o jsonpath='{.metadata.creationTimestamp}')
start=$(kubectl -n test-scheduler get pod test-nginx-pod -o jsonpath='{.status.startTime}')
echo "Tiempo total en segundos: $(( $(date -d "$start" +%s) - $(date -d "$creation" +%s) ))"
```

- Antes: Pending
- Después: Running
- Tiempo total = Scheduling + Container start.

 **El resultado son : Tiempo total en segundos: 4**


Tambiém podemos verlo con los eventos que genera `my-scheduler` :

```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl get events -n test-scheduler --field-selector involvedObject.name=test-nginx-pod --sort-by=.metadata.creationTimestamp
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
kubectl get events -n test-scheduler --field-selector involvedObject.name=test-nginx-pod --sort-by=.metadata.creationTimestamp \
-o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{"\n"}{end}' | grep -E 'Pulling|Started' | awk '
/Pulling/ {pull=$1; pull_time=$2}
/Started/ {start=$1; start_time=$2; print "Interval: " pull " -> " start ", duration approx: " (mktime(gensub(/[-:T]/," ","g",start))-mktime(gensub(/[-:T]/," ","g",pull))) "s"}'
```
El resultado de aplicar el comadno es:

```Bash
jogugil@PHOSKI:~/kubernetes_ejemplos/scheduler/py-scheduler-repo.o/py-scheduler$ kubectl get events -n test-scheduler --field-selector involvedObject.name=test-nginx-pod --sort-by=.metadata.creationTimestamp \
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

En los pasos anteriores ya mostramos las capturas de pantalla y todos las acciones realizados para el despliegue del scheduler personalizado (scheduler-polling) y la cpatura de las métricas. En ekl vinmos como el cheduiler-polling asigna un nodo al Pod `test-pod` cuando éste es desplegado dentro del clúster. 

Para hacerlo automatizado creamos un script que permite crear el clúster, lanzar el scheduler, los pods de pruebas y calcular las metricas de latencia y carga de nuestro scheduler. LAs funciones que calculan las métricas se meustra a continuación:

- ***`scheduler-test.sh`***
  
```Bash
# Función para test de latencia manual
run_improved_latency_test() {
    local pod_name=$1
    local yaml_file=$2
    local test_name=$3

    echo ""
    echo "=== TEST MÉTRICAS: $test_name ==="

    # Limpiar pod previo
    kubectl delete pod $pod_name -n $NAMESPACE --ignore-not-found=true
    sleep 3

    # Obtener el pod del scheduler
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')

    # TIMESTAMP INICIAL en formato ISO para --since-time
    local start_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "TIMESTAMP INICIAL: $start_timestamp"

    local list_before=0
    if [[ -n "$scheduler_pod" ]]; then
        echo "=== Contando operaciones LIST ANTES del scheduling ==="
        # Método 1: Buscar operaciones de listado en logs recientes
        list_before=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | \
           grep -c -E "list.*pods|List.*pods|get.*pods|Get.*pods|watching|Watching" 2>/dev/null || echo "0")

        # LIMPIAR el valor
        list_before=$(echo "$list_before" | tr -d '\n' | tr -d ' ' | tr -d '\r')
        [[ -z "$list_before" ]] && list_before=0

        # Método 2: Si es 0, contar líneas totales recientes como estimación
        if [[ "$list_before" -eq "0" ]]; then
            list_before=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | wc -l 2>/dev/null || echo "0")
            list_before=$(echo "$list_before" | tr -d '\n' | tr -d ' ' | tr -d '\r')
            [[ -z "$list_before" ]] && list_before=0
        fi
    fi
    echo "Operaciones LIST ANTES: $list_before"

    # Registrar tiempo inicial
    local t0_sec=$(date -u +%s)
    echo "T0 (apply): $(date -u +"%H:%M:%S") - $t0_sec"

    kubectl apply -f $yaml_file -n $NAMESPACE
    echo "Pod $pod_name aplicado"

    # Esperar a que el pod esté listo
    kubectl wait --for=condition=Ready pod/$pod_name -n $NAMESPACE --timeout=120s

    # Pequeña pausa para logs
    sleep 5

    # OBTENER LOGS SOLO DESDE EL INICIO DEL TEST
    local test_logs=""
    if [[ -n "$scheduler_pod" ]]; then
        test_logs=$(kubectl -n kube-system logs "$scheduler_pod" --since-time="$start_timestamp" 2>/dev/null || echo "")
        echo "Logs capturados durante test: $(echo "$test_logs" | wc -l) líneas"
    fi

    # 2. Latencia del scheduler - BUSCAR EN LOGS DEL TEST
    # Obtener timestamp del último binding
    local t1_ts=$(kubectl -n kube-system logs -l app=$SCHEDULER_NAME --timestamps 2>/dev/null | \
               grep "Bound $NAMESPACE/$pod_name" | tail -1 | awk '{print $1}')

    local scheduler_latency="N/A"
    if [[ -n "$t1_ts" ]]; then
        # Convertir el timestamp ISO 8601 directamente a epoch con nanosegundos
        local t1_epoch=$(date -u -d "$t1_ts" +%s.%N 2>/dev/null || echo "0")
        if [[ $(echo "$t1_epoch > 0" | bc -l) -eq 1 ]]; then
            # Calcular latencia como decimal
            scheduler_latency=$(echo "$t1_epoch - $t0_sec" | bc -l)
        fi
    fi
    echo "Latencia scheduler: $scheduler_latency segundos"


    # 4. Latencia Pull->Start
    local pull_start_latency=$(get_pull_start_latency "$pod_name" "$NAMESPACE")
    echo "Latencia Pull→Start: $pull_start_latency"

    # 5. Métricas de recursos
    read -r avg_cpu avg_mem <<< "$(get_scheduler_resources_avg)"
    echo "CPU (avg): $avg_cpu - MEM (avg): $avg_mem"

  # 6. CONTAR OPERACIONES LIST DESPUÉS del scheduling y CALCULAR DIFERENCIA
    local list_after=0
    local list_ops=0

    if [[ -n "$scheduler_pod" ]]; then
        echo "=== Contando operaciones LIST DESPUÉS del scheduling ==="
        # Esperar un poco para que se registren todos los logs
        sleep 2

        # Contar operaciones DESPUÉS del scheduling.  --since=1m para obtener sólo los últimos
        list_after=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | \
        grep -c -E "list.*pods|List.*pods|get.*pods|Get.*pods|watching|Watching" 2>/dev/null || echo "0")

        # LIMPIAR el valor - eliminar saltos de línea y espacios
        list_after=$(echo "$list_after" | tr -d '\n' | tr -d ' ' | tr -d '\r')

        # Si está vacío, poner 0
        if [[ -z "$list_after" ]]; then
            list_after=0
        fi

        # Si sigue siendo 0, contar líneas totales recientes como estimación
        if [[ "$list_after" -eq "0" ]]; then
            list_after=$(kubectl -n kube-system logs "$scheduler_pod" --since=1m | grep $pod_name 2>/dev/null | wc -l 2>/dev/null || echo "0")
            list_after=$(echo "$list_after" | tr -d '\n' | tr -d ' ' | tr -d '\r')
            [[ -z "$list_after" ]] && list_after=0
        fi

        # Calcular diferencia (las operaciones durante el scheduling)
        list_ops=$((list_after - list_before))

        # Asegurar que no sea negativo
        if [[ $list_ops -lt 0 ]]; then
            list_ops=0
        fi
        echo "Operaciones LIST DESPUÉS: $list_after"
        echo "Operaciones LIST DURANTE scheduling: $list_ops"
    else
        echo "No se pudo encontrar el pod del scheduler para contar operaciones LIST"
    fi

    echo "LIST Ops (scheduler): $list_ops"

    # 7. Número de re-intentos del scheduler
    local implicit_retries=0
    local retry_count=0
    if [[ -n "$scheduler_pod" ]]; then
        # a. Total de intentos de scheduling
        # Obtener y limpiar total_attempts
        total_attempts=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
             grep -c "Attempting to schedule pod: $NAMESPACE/$POD_NAME" || echo "0")

        total_attempts=$(clean_numeric_value "$total_attempts")

        # b. Obtener y limpiar successful_schedules
        successful_schedules=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
              grep -c "Bound $NAMESPACE/$POD_NAME" || echo "0")
        successful_schedules=$(clean_numeric_value "$successful_schedules")

        echo "total_attempts: [$total_attempts]"
        echo "successful_schedules: [$successful_schedules]"

        # c. Calcular reintentos
        retry_count=$(kubectl -n kube-system logs "$scheduler_pod" | grep $pod_name 2>/dev/null | \
            grep -c "retry\|Retry\|retrying\|error\|Error" || echo "0")
        # Limpiar cualquier salto de línea
        retry_count=$(echo "$retry_count" | tr -d '\n' | tr -d ' ')

        # Reintentos implícitos: intentos - éxitos
        echo "total_attempts: $total_attempts"
        echo "successful_schedules): $successful_schedules)"
        implicit_retries=$((total_attempts - successful_schedules))
        echo "Re-intentos implícitos (total - exitosos): $implicit_retries"
     fi
     echo "Re-intentos explícitos: $retry_count"
     echo "Re-intentos implícitos (total - exitosos): $implicit_retries"

    # 8. Eventos de binding
    local scheduler_events=0
    # Limpiar pod previo
    kubectl delete pod $pod_name -n $NAMESPACE --ignore-not-found=true
    sleep 3

    if [[ -n "$scheduler_pod" ]]; then
        scheduler_events=$(kubectl -n kube-system logs "$scheduler_pod" | grep $pod_name 2>/dev/null | \
            grep -c "Bound.*$pod_name\|Scheduled.*$pod_name" || echo "0")
        scheduler_events=$(echo "$scheduler_events" | tr -d '\n' | tr -d ' ')
    fi

    echo "Eventos de binding para $pod_name: $scheduler_events"

    # 3. Latencia Pending -> Running. Lo pasamos aqui para forzar la  métrica. Volvemos a borrar el Pod y crearlo deneuvo
    # para modificar los cambios de estado y ver el tiempo que le cuesta llegar a running

    # Limpiar pod previo
    kubectl delete pod $pod_name -n $NAMESPACE --ignore-not-found=true
    sleep 3
    # Volvems a arrancar el Pod para cambiar el estado
    kubectl apply -f $yaml_file -n $NAMESPACE
    echo "Pod $pod_name aplicado"

    # Esperar a que el pod esté listo
    kubectl wait --for=condition=Ready pod/$pod_name -n $NAMESPACE --timeout=120s

    # Pequeña pausa para logs
    sleep 5
    # Notar que lso sleeps no afectan al Pod. En neustro caso es 0 porque  los Pods no tienen mucha carga y el estado a running es rápido
    local creation_time=$(kubectl -n $NAMESPACE get pod $pod_name -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    local start_time=$(kubectl -n $NAMESPACE get pod $pod_name -o jsonpath='{.status.startTime}' 2>/dev/null)

    local latency_pending_running="N/A"
    if [[ -n "$creation_time" && -n "$start_time" ]]; then
        local creation_sec=$(date -d "$creation_time" +%s 2>/dev/null)
        local start_sec=$(date -d "$start_time" +%s 2>/dev/null)
        if [[ $creation_sec -gt 0 && $start_sec -gt 0 ]]; then
            latency_pending_running=$((start_sec - creation_sec))
        fi
    fi
    echo "Latencia Pending→Running: $latency_pending_running s"



    # Guardar métricas
    if [[ "$pod_name" == "test-pod" ]]; then
        METRICS_TEST_POD["latency"]=$scheduler_latency
        METRICS_TEST_POD["latency_pending_running"]=$latency_pending_running
        METRICS_TEST_POD["list_ops"]=$list_ops
        METRICS_TEST_POD["cpu"]=$avg_cpu
        METRICS_TEST_POD["mem"]=$avg_mem
        METRICS_TEST_POD["pull_start_latency"]=$pull_start_latency
        METRICS_TEST_POD["retries"]=$retry_count
        METRICS_TEST_POD["implicit_retries"]=$implicit_retries
        METRICS_TEST_POD["events"]=$scheduler_events
    else
        METRICS_NGINX_POD["latency"]=$scheduler_latency
        METRICS_NGINX_POD["latency_pending_running"]=$latency_pending_running
        METRICS_NGINX_POD["list_ops"]=$list_ops
        METRICS_NGINX_POD["cpu"]=$avg_cpu
        METRICS_NGINX_POD["mem"]=$avg_mem
        METRICS_NGINX_POD["pull_start_latency"]=$pull_start_latency
        METRICS_NGINX_POD["retries"]=$retry_count
        METRICS_NGINX_POD["implicit_retries"]=$implicit_retries
        METRICS_NGINX_POD["events"]=$scheduler_events
    fi

    return 0
}

# Función para análisis detallado de scheduling QUE USA LAS MÉTRICAS DE run_improved_latency_test
analyze_scheduling_detailed() {
    local pod_name=$1
    local namespace=$2
    local test_name=$3
    # Obtener el pod del scheduler
    local scheduler_pod=$(kubectl -n kube-system get pods -l app=$SCHEDULER_NAME -o name 2>/dev/null | head -1 | sed 's#pod/##')

    echo ""
    echo "=== ANÁLISIS DETALLADO (USANDO MÉTRICAS): $test_name ==="

    # Obtener métricas de los arrays globales
    local scheduling_latency="N/A"
    local pending_running_latency="N/A"
    local pull_start_latency="N/A"
    local cpu_usage="N/A"
    local mem_usage="N/A"
    local list_ops="N/A"
    local retry_count="N/A"

    if [[ "$pod_name" == "test-pod" ]]; then
        scheduling_latency=${METRICS_TEST_POD["latency"]}
        pending_running_latency=${METRICS_TEST_POD["latency_pending_running"]}
        pull_start_latency=${METRICS_TEST_POD["pull_start_latency"]}
        cpu_usage=${METRICS_TEST_POD["cpu"]}
        mem_usage=${METRICS_TEST_POD["mem"]}
        list_ops=${METRICS_TEST_POD["list_ops"]}
        retry_count=${METRICS_TEST_POD["retries"]}
        events=${METRICS_TEST_POD["events"]}
    else
        scheduling_latency=${METRICS_NGINX_POD["latency"]}
        pending_running_latency=${METRICS_NGINX_POD["latency_pending_running"]}
        pull_start_latency=${METRICS_NGINX_POD["pull_start_latency"]}
        cpu_usage=${METRICS_NGINX_POD["cpu"]}
        mem_usage=${METRICS_NGINX_POD["mem"]}
        list_ops=${METRICS_NGINX_POD["list_ops"]}
        retry_count=${METRICS_NGINX_POD["retries"]}
        events=${METRICS_NGINX_POD["events"]}
    fi

    # Throughput reciente
    local recent_schedules=$(kubectl -n kube-system logs -l app=$SCHEDULER_NAME --since=5m 2>/dev/null \
                              | grep "$pod_name" \
                              | grep -c "Bound")

    # Si recent_schedules está vacío, usar 0
    recent_schedules=${recent_schedules:-0}

    echo "recent_schedules: [$recent_schedules]"

    local throughput=$((recent_schedules * 12))  # pods por hora

    # Tasa de éxito

    local total_attempts=0
    local successful_schedules=0
    local success_rate="N/A"

    # Obtener y limpiar total_attempts
    total_attempts=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
        grep -c "Attempting to schedule pod: $NAMESPACE/$POD_NAME" || echo "0")

    total_attempts=$(clean_numeric_value "$total_attempts")

    # Obtener y limpiar successful_schedules
    successful_schedules=$(kubectl -n kube-system logs "$scheduler_pod" --since=1h 2>/dev/null | \
        grep -c "Bound $NAMESPACE/$POD_NAME" || echo "0")
    successful_schedules=$(clean_numeric_value "$successful_schedules")

    echo "total_attempts: [$total_attempts]"
    echo "successful_schedules: [$successful_schedules]"

    if [[ $total_attempts -gt 0 ]]; then
        # Usar awk para evitar problemas con bc
        success_rate=$(awk "BEGIN {printf \"%.2f\", $successful_schedules * 100 / $total_attempts}" 2>/dev/null || echo "0")
    else
        success_rate="0"
    fi


    # Estado del cluster
    local cluster_state=$(get_cluster_state)


    # Carga compuesta (solo si tenemos latencia numérica)
    local composite_load="N/A"
    if [[ "$scheduling_latency" =~ ^[0-9]+$ ]]; then
        composite_load=$(calculate_composite_metrics "$scheduling_latency" "$cpu_usage" "$mem_usage" "$success_rate")
    fi

    # Mostrar resultados
    echo "  - Latencia Scheduling: ${scheduling_latency}s"
    echo "  - Latencia Pending→Running: ${pending_running_latency}s"
    echo "  - Latencia Pull→Start: ${pull_start_latency}s"
    echo "  - Re-intentos scheduler: $retry_count"
    echo "  - Throughput: $throughput pods/h"
    echo "  - Tasa de éxito: ${success_rate}%"
    echo "  - CPU: $cpu_usage, Mem: $mem_usage"
    echo "  - Operaciones LIST: $list_ops"
    echo "  - Estado cluster: $cluster_state"
    echo "  - Eventos: $events"

    # Solo mostrar carga compuesta si es numérica
    if [[ "$composite_load" != "N/A" ]]; then
        echo "  - Carga compuesta: $composite_load/100"

        # Interpretación de carga (CORREGIDO - sin error de "too many arguments")
        if [[ "$composite_load" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            if (( $(echo "$composite_load < 30" | bc -l 2>/dev/null) )); then
                echo "  - CARGA: BAJA ✅"
            elif (( $(echo "$composite_load < 70" | bc -l 2>/dev/null) )); then
                echo "  - CARGA: MODERADA ⚠️"
            else
                echo "  - CARGA: ALTA ❌"
            fi
        else
            echo "  - CARGA: NO DISPONIBLE"
        fi
    else
        echo "  - Carga compuesta: N/A"
        echo "  - CARGA: NO DISPONIBLE"
    fi

    # Registrar métricas en CSV
    record_metrics "$test_name" "$pod_name" "$scheduling_latency" "N/A" "N/A" "$pending_running_latency" \
                   "$pull_start_latency" "$cpu_usage" "$mem_usage" "$list_ops" "$success_rate" "$composite_load" "$cluster_state"
}
```

Estas funciones se encuntran dentro del script [***`scheduler-test.sh`***](py-scheduler/scheduler-test.sh)

Los resultados para este scheduler polling son:

 ```Bash
=== TEST MÉTRICAS: test-pod ===
TIMESTAMP INICIAL: 2025-11-09T13:43:38Z
=== Contando operaciones LIST ANTES del scheduling ===
Operaciones LIST ANTES: 0
T0 (apply): 13:43:38 - 1762695818
pod/test-pod created
Pod test-pod aplicado
pod/test-pod condition met
Logs capturados durante test: 9 líneas
Latencia scheduler: 1.004270112 segundos
Latencia Pull→Start: 2
CPU (avg): 315m - MEM (avg): 58Mi
=== Contando operaciones LIST DESPUÉS del scheduling ===
Operaciones LIST DESPUÉS: 5
Operaciones LIST DURANTE scheduling: 5
LIST Ops (scheduler): 5
total_attempts: [1]
successful_schedules: [1]
total_attempts: 1
successful_schedules): 1)
Re-intentos implícitos (total - exitosos): 0
Re-intentos explícitos: 00
Re-intentos implícitos (total - exitosos): 0
pod "test-pod" deleted from test-scheduler namespace
Eventos de binding para test-pod: 1
pod/test-pod created
Pod test-pod aplicado
pod/test-pod condition met
Latencia Pending→Running: 0 s

=== ANÁLISIS DETALLADO (USANDO MÉTRICAS): test_basic_detailed ===
recent_schedules: [2]
total_attempts: [2]
successful_schedules: [2]
  - Latencia Scheduling: 1.004270112s
  - Latencia Pending→Running: 0s
  - Latencia Pull→Start: 2s
  - Re-intentos scheduler: 00
  - Throughput: 24 pods/h
  - Tasa de éxito: 100.00%
  - CPU: 315m, Mem: 58Mi
  - Operaciones LIST: 5
  - Estado cluster: 1/1
  - Eventos: 1
  - Carga compuesta: N/A
  - CARGA: NO DISPONIBLE

=== TEST MÉTRICAS: test-nginx-pod ===
TIMESTAMP INICIAL: 2025-11-09T13:44:26Z
=== Contando operaciones LIST ANTES del scheduling ===
Operaciones LIST ANTES: 0
T0 (apply): 13:44:27 - 1762695867
pod/test-nginx-pod created
Pod test-nginx-pod aplicado
pod/test-nginx-pod condition met
Logs capturados durante test: 9 líneas
Latencia scheduler: .589661990 segundos
Latencia Pull→Start: 2
CPU (avg): 274m - MEM (avg): 59Mi
=== Contando operaciones LIST DESPUÉS del scheduling ===
Operaciones LIST DESPUÉS: 5
Operaciones LIST DURANTE scheduling: 5
LIST Ops (scheduler): 5
total_attempts: [2]
successful_schedules: [2]
total_attempts: 2
successful_schedules): 2)
Re-intentos implícitos (total - exitosos): 0
Re-intentos explícitos: 00
Re-intentos implícitos (total - exitosos): 0
pod "test-nginx-pod" deleted from test-scheduler namespace
Eventos de binding para test-nginx-pod: 1
pod/test-nginx-pod created
Pod test-nginx-pod aplicado
pod/test-nginx-pod condition met
Latencia Pending→Running: 0 s

=== ANÁLISIS DETALLADO (USANDO MÉTRICAS): test_nginx_detailed ===
recent_schedules: [2]
total_attempts: [2]
successful_schedules: [2]
  - Latencia Scheduling: .589661990s
  - Latencia Pending→Running: 0s
  - Latencia Pull→Start: 2s
  - Re-intentos scheduler: 00
  - Throughput: 24 pods/h
  - Tasa de éxito: 100.00%
  - CPU: 274m, Mem: 59Mi
  - Operaciones LIST: 5
  - Estado cluster: 1/1
  - Eventos: 1
  - Carga compuesta: N/A
  - CARGA: NO DISPONIBLE

=== RESUMEN FINAL ===
Métricas guardadas en: scheduler_metrics_20251109_144130.csv

=== COMPARATIVA FINAL (MÉTRICAS) ===
Pod             | LatPolling(s) | LatPending->Run(s)   | LIST   | CPU      | Mem      | Pull->Start(s) | Retries    | Events   | Implicits_Retries
----------------+--------------+----------------------+--------+----------+----------+----------------+------------+----------+-------------------
test-pod        | 1.004270112  | 0                    | 5      | 315m     | 58Mi     | 2              | 00         | 1        | 0
test-nginx-pod  | .589661990   | 0                    | 5      | 274m     | 59Mi     | 2              | 00         | 1        | 0
```

## 🧩 Step 7 — Event-Driven Scheduler (Watch API)

En este paso modificamos `my_scheduler`del cluster para que se ejecute la versión `watch`. Realizamos todos los pasos anteriores para cargar la imagen con mi nuevo `scheduler_watch` y calcular las nuevas métricas.

Ahora ya no listamos todos lso Pod's que tenemos, sino que creamos un watch por cad auno y cuando nos llega el evento asociado al Pod ejecutamos una acción determinada. El código del nmuevo scheduler es el siguiente:

```Python
import argparse, time, math
from kubernetes import client, config, watch

import signal
import sys

running = True

# Handler para Ctrl+C o SIGTERM
def signal_handler(sig, frame):
    global running
    print("[info] Señal de terminación recibida, deteniendo scheduler...")
    running = False

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# Cargar cliente
def load_client(kubeconfig=None):
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

# Bind de pod a nodo
def bind_pod(api, pod, node_name):
    target = client.V1ObjectReference(api_version="v1", kind="Node", name=node_name)
    metadata = client.V1ObjectMeta(name=pod.metadata.name)
    body = client.V1Binding(target=target, metadata=metadata)
    api.create_namespaced_binding(namespace=pod.metadata.namespace, body=body)
    print(f"[bind] Pod {pod.metadata.namespace}/{pod.metadata.name} -> {node_name}")

# Elegir nodo según menos carga
def choose_node(api, pod):
    nodes = api.list_node().items
    pods = api.list_pod_for_all_namespaces().items
    node_load = {n.metadata.name: 0 for n in nodes}
    for p in pods:
        if p.spec.node_name:
            node_load[p.spec.node_name] += 1
    node = min(node_load, key=node_load.get)
    print(f"[policy] Nodo elegido para {pod.metadata.name}: {node}")
    return node

# Diccionario global para métricas
METRICS = {}

def record_trace(pod, event_type, timestamp=None):
    ts = timestamp or time.time()
    key = f"{pod.metadata.namespace}/{pod.metadata.name}"
    if key not in METRICS:
        METRICS[key] = {"added": None, "scheduled": None, "bound": None}
    if event_type == "ADDED":
        METRICS[key]["added"] = ts
        print(f"[trace] {key} ADDED at {ts}")
    elif event_type == "SCHEDULED":
        METRICS[key]["scheduled"] = ts
        print(f"[trace] {key} SCHEDULED at {ts}")
    elif event_type == "BOUND":
        METRICS[key]["bound"] = ts
        print(f"[trace] {key} BOUND at {ts}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scheduler-name", default="my-scheduler")
    parser.add_argument("--kubeconfig", default=None)
    args = parser.parse_args()

    api = load_client(args.kubeconfig)
    print(f"[watch] scheduler starting… name={args.scheduler_name}")

    w = watch.Watch()
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

                # Detectar pod pendiente y scheduler custom
                if (pod.status.phase == "Pending" and
                    pod.spec.scheduler_name == args.scheduler_name and
                    not pod.spec.node_name):
                    
                    record_trace(pod, "ADDED")
                    try:
                        node = choose_node(api, pod)
                        bind_pod(api, pod, node)
                        record_trace(pod, "BOUND")
                        print(f"[success] {pod.metadata.namespace}/{pod.metadata.name} -> {node}")
                    except Exception as e:
                        print(f"[error] Error al programar {pod.metadata.name}: {e}")
        except Exception as e:
            if running:
                print(f"[warn] Watch detenido de forma limpia: {e}")

if __name__ == "__main__":
    main()
```
Ejecutamos el script creado en el apartado anterior y obtnemos los siguientes resultados par el despliegue de los mismos Pods:

```Bash
=== TEST MÉTRICAS: test-pod ===
TIMESTAMP INICIAL: 2025-11-09T14:00:29Z
=== Contando operaciones LIST ANTES del scheduling ===
Operaciones LIST ANTES: 0
T0 (apply): 14:00:30 - 1762696830
pod/test-pod created
Pod test-pod aplicado
pod/test-pod condition met
Logs capturados durante test: 3 líneas
Latencia scheduler: N/A segundos
Latencia Pull→Start: 2
CPU (avg): 1m - MEM (avg): 58Mi
=== Contando operaciones LIST DESPUÉS del scheduling ===
Operaciones LIST DESPUÉS: 3
Operaciones LIST DURANTE scheduling: 3
LIST Ops (scheduler): 3
total_attempts: [0]
successful_schedules: [0]
total_attempts: 0
successful_schedules): 0)
Re-intentos implícitos (total - exitosos): 0
Re-intentos explícitos: 1
Re-intentos implícitos (total - exitosos): 0
pod "test-pod" deleted from test-scheduler namespace
Eventos de binding para test-pod: 00
pod/test-pod created
Pod test-pod aplicado
pod/test-pod condition met
Latencia Pending→Running: 0 s

=== ANÁLISIS DETALLADO (USANDO MÉTRICAS): test_basic_detailed ===
recent_schedules: [0]
total_attempts: [0]
successful_schedules: [0]
  - Latencia Scheduling: N/As
  - Latencia Pending→Running: 0s
  - Latencia Pull→Start: 2s
  - Re-intentos scheduler: 1
  - Throughput: 0 pods/h
  - Tasa de éxito: 0%
  - CPU: 1m, Mem: 58Mi
  - Operaciones LIST: 3
  - Estado cluster: 1/1
  - Eventos: 00
  - Carga compuesta: N/A
  - CARGA: NO DISPONIBLE


=== TEST MÉTRICAS: test-nginx-pod===
TIMESTAMP INICIAL: 2025-11-09T14:01:14Z
=== Contando operaciones LIST ANTES del scheduling ===
Operaciones LIST ANTES: 0
T0 (apply): 14:01:14 - 1762696874
pod/test-nginx-pod created
Pod test-nginx-pod aplicado
pod/test-nginx-pod condition met
Logs capturados durante test: 3 líneas
Latencia scheduler: N/A segundos
Latencia Pull→Start: 3
CPU (avg): 3m - MEM (avg): 58Mi
=== Contando operaciones LIST DESPUÉS del scheduling ===
Operaciones LIST DESPUÉS: 3
Operaciones LIST DURANTE scheduling: 3
LIST Ops (scheduler): 3
total_attempts: [0]
successful_schedules: [0]
total_attempts: 0
successful_schedules): 0)
Re-intentos implícitos (total - exitosos): 0
Re-intentos explícitos: 1
Re-intentos implícitos (total - exitosos): 0
pod "test-nginx-pod" deleted from test-scheduler namespace
Eventos de binding para test-nginx-pod: 00
pod/test-nginx-pod created
Pod test-nginx-pod aplicado
pod/test-nginx-pod condition met
Latencia Pending→Running: 0 s

=== ANÁLISIS DETALLADO (USANDO MÉTRICAS): test_nginx_detailed ===
recent_schedules: [0]
total_attempts: [0]
successful_schedules: [0]
  - Latencia Scheduling: N/As
  - Latencia Pending→Running: 0s
  - Latencia Pull→Start: 3s
  - Re-intentos scheduler: 1
  - Throughput: 0 pods/h
  - Tasa de éxito: 0%
  - CPU: 3m, Mem: 58Mi
  - Operaciones LIST: 3
  - Estado cluster: 1/1
  - Eventos: 00
  - Carga compuesta: N/A
  - CARGA: NO DISPONIBLE

=== RESUMEN FINAL ===
Métricas guardadas en: scheduler_metrics_20251109_145826.csv

=== COMPARATIVA FINAL (MÉTRICAS) ===
Pod             | LatPolling(s) | LatPending->Run(s)   | LIST   | CPU      | Mem      | Pull->Start(s) | Retries    | Events   | Implicits_Retries
----------------+--------------+----------------------+--------+----------+----------+----------------+------------+----------+-------------------
test-pod        | N/A          | 0                    | 3      | 1m       | 58Mi     | 2              | 1          | 00       | 0
test-nginx-pod  | N/A          | 0                    | 3      | 3m       | 58Mi     | 3              | 1          | 00       | 0

```

### ✅**Checkpoint 4:**
***Compare responsiveness and efficiency between polling and watch approaches.***

Vemos en lso resultados de las métricas que la latencia es mínima en el caso del `scheduler-watch`de hecho la resolución es tan pequeña que es nula. Del mismo modo las operaciones sobnre APiserv(LIST) o inclso el uso de cpu es menor al tene menos peticiones al APISERV. 
Aunque estas métricas no son representativas ya que se realzian con dos simples despliequesx de dos pods con carga baja. Aún así, se ve que la eficiencia del tipo `watch`es mayor a la del `polling`.


```Bash

=== RESUMEN FINAL: scheduler - polling ===
Métricas guardadas en: scheduler_metrics_20251109_144130.csv

=== COMPARATIVA FINAL (MÉTRICAS) ===
Pod             | LatPolling(s) | LatPending->Run(s)   | LIST   | CPU      | Mem      | Pull->Start(s) | Retries    | Events   | Implicits_Retries
----------------+--------------+----------------------+--------+----------+----------+----------------+------------+----------+-------------------
test-pod        | 1.004270112  | 0                    | 5      | 315m     | 58Mi     | 2              | 00         | 1        | 0
test-nginx-pod  | .589661990   | 0                    | 5      | 274m     | 59Mi     | 2              | 00         | 1        | 0

=== RESUMEN FINAL : scheduler-watch ===
Métricas guardadas en: scheduler_metrics_20251109_145826.csv

=== COMPARATIVA FINAL (MÉTRICAS) ===
Pod             | LatPolling(s) | LatPending->Run(s)   | LIST   | CPU      | Mem      | Pull->Start(s) | Retries    | Events   | Implicits_Retries
----------------+--------------+----------------------+--------+----------+----------+----------------+------------+----------+-------------------
test-pod        | N/A          | 0                    | 3      | 1m       | 58Mi     | 2              | 1          | 00       | 0
test-nginx-pod  | N/A          | 0                    | 3      | 3m       | 58Mi     | 3              | 1          | 00       | 0

```

Comparamos los valores obteneidos por lso scripts para cad auno de los tipos de scheduler para los mismnos Pods de prueba. En un principio tenemos que ver que los valores para el scheduler de tipo watch son mejroes que para el tipo polling. 

Para poder hacer una comparación más exhaustiva **se han creado unos scripts para lanzar Pods con mayor carga** y un **pequeño benchmarking** que despliega varios Pods, `calculando las métricas medias para cada tipo de scheduler` . Los scripts se encuentran en el subdirectorio `benchmarking`. 

## 🧩 Step 8 — Policy Extensions

### 1. Label-based node filtering

Para que los pods solo se ejecuten en nodos de producción, el scheduler personalizado usa la función `is_node_compatible(node, pod)`, que evalúa si un nodo puede recibir un pod según estas reglas:

- Filtro por label `env=prod` en el nodo: solo los nodos que tengan `env=prod` se consideran compatibles. Esto evita que los pods se programen en nodos de desarrollo o test.

- Compatibilidad con taints/tolerations: si el pod no tiene tolerations se considera compatible; si las tiene, cada taint del nodo se comprueba y un taint no tolerado hace que el nodo se considere incompatible.

```python
def is_node_compatible(node, pod):

    # --- FILTRO DE NODOS POR LABEL env=prod ---
    node_env = node.metadata.labels.get("env") if node.metadata.labels else None
    if node_env != "prod":
        return False

    if not pod.spec.tolerations:
        return True
    node_taints = node.spec.taints or []
    for taint in node_taints:
        tolerated = any(
            t.key == taint.key and t.effect == taint.effect and (t.value == taint.value if t.value else True)
            for t in pod.spec.tolerations
        )
        if not tolerated:
            return False
    return True
```

Esto asegura que:

- El scheduler solo considere nodos prod para programar cualquier pod.

- Los pods se asignen al nodo prod con menos carga (función choose_node).

- Si no hay nodos compatibles, el pod se rechaza o queda Pending según la política.

La función para la elección del nodo (choose_node):

```python
def choose_node(api, pod):
    nodes = [n for n in api.list_node().items if is_node_compatible(n, pod)]
    if not nodes:
        return None  # No hay nodos compatibles → pod rechazado

    pods = api.list_pod_for_all_namespaces().items
    node_load = {n.metadata.name: 0 for n in nodes}

    pod_app_label = pod.metadata.labels.get("app") if pod.metadata.labels else None
    for p in pods:
        if p.spec.node_name in node_load:
            if not pod_app_label or (p.metadata.labels and p.metadata.labels.get("app") == pod_app_label):
                node_load[p.spec.node_name] += 1

    node = min(node_load, key=node_load.get)
    print(f"[policy] Nodo elegido para {pod.metadata.name}: {node}")
    return node
```
- Se consideran todos lso nodos de producción con `env=prod`
- Se consideran todos los nodos compatibles con el pod (según tolerations/taints).
- Se balancea la carga de pods según su label app.
- Si no hay nodos disponibles, la función devuelve None y el pod se rechaza.

***Nota:*** *Para gestionar la distribución de carga de los pods en nuestros nodos de producción, hemos decidido usar el mismo valor de label app (my-scheduler) en todos los pods. De esta forma, el scheduler personalizado los considera parte de un mismo grupo y los distribuye equilibradamente entre los nodos disponibles, evitando que unos pods acaparen determinados nodos mientras otros quedan vacíos. Si quisiéramos balancear la carga por tipo de pod, podríamos asignar un app distinto a cada tipo, pero para nuestro caso nos resulta más sencillo mantener un valor único y garantizar una distribución uniforme. 

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: test-scheduler
  labels:
    app: my-scheduler
spec:
  schedulerName: my-scheduler
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
```
  
Los pasos para comprobar el funcionamiento del scheduler personalizado, ahora basado en filtrado por nodos de producción `(env=prod)`, son los siguientes:

1. Borrar el cluster existente
```bash
kind delete cluster --name sched-lab
```
2. Crear un nuevo cluster
```bash
kind create cluster --name sched-lab --config kind-config.yaml
```
Notar que hemos creado u n uevop manifiesto para crear un cluster con un `control plane` y dos `workers`para comprobar el fioltrado por nodo.

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
``` 
También debemos modificar el manifiesto del `my-scheduler` añadiendo el bloque de `tolerations` y un `nodeSelector` para que el pod pueda programarse en el nodo control-plane, que `por defecto` tiene un `taint` que `evita que se ejecuten pods no tolerantes`. Esto asegura que el `scheduler personalizado` utilice la imagen que hemos cargado localmente en el nodo del control plane y arranque correctamente sin intentar tirar del registry externo.

```yaml
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
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        effect: "NoSchedule"
      nodeSelector:
        kubernetes.io/hostname: sched-lab-control-plane
      containers:
      - name: scheduler
        image: my-py-scheduler:latest
        imagePullPolicy: Never
        args: ["--scheduler-name","my-scheduler"]
```
        
3. Verificar que el cluster está listo
```bash
kubectl cluster-info --context kind-sched-lab
kubectl get nodes
```
<img width="1228" height="521" alt="image" src="https://github.com/user-attachments/assets/77ad5269-15cd-44d7-b39c-fb5ef59268f2" />

Vemos que el cluster está listo con el `control plane` y los dos `workers`.

4. Construir la nueva imagen del scheduler:

```bash
docker build --no-cache -t my-py-scheduler:latest .
```

5. Cargar la imagen en Kind:

```bash
kind load docker-image my-py-scheduler:latest --name sched-lab --nodes sched-lab-control-plane
```

6. Verificar que la imagen está en el control-plane:

```bash
docker exec -it sched-lab-control-plane crictl images | grep my-py-scheduler
```
<img width="1225" height="536" alt="image" src="https://github.com/user-attachments/assets/04c16665-547e-4820-b880-a22709818f77" />
Comprobamos que la imagen de mi `my-py-scheduler`está en el `control plane` cargada.

7. Crear namespace para pruebas:

```bash
kubectl create namespace test-scheduler
```

8.  Desplegar el scheduler custom solo en control-plane

```bash
kubectl apply -f rbac-deploy.yaml
kubectl get deployment -n kube-system
kubectl get pods -n kube-system
```
<img width="1234" height="499" alt="image" src="https://github.com/user-attachments/assets/d47a7e8f-a871-4ccf-82bc-c407e55cb868" />

Vemos que tenemos cargado el `my-scheduler` en el `control plane`.

9. Etiquetar nodos como producción (env=prod) para que el scheduler los considere:

```bash
kubectl label node sched-lab-control-plane env=prod
kubectl label node sched-lab-worker env=prod
```

10. Aplicar pods de prueba:

```bash
kubectl apply -f test-pod.yaml -n test-scheduler       
kubectl apply -f test-nginx-pod.yaml -n test-scheduler  
```

11. Ver estado de los pods:

```bash
kubectl get pods -n test-scheduler -o wide
```

12. Revisar eventos del namespace:

```bash
kubectl get events -n test-scheduler --sort-by='.metadata.creationTimestamp'
```

 <img width="1234" height="529" alt="image" src="https://github.com/user-attachments/assets/fdba61cf-7ba0-4f6d-b67a-7e62383bf373" />

Vemos como los `pods`se asignaron al nodo `sched-lab-worker` que es quien tiene el label `env=prod`. 

Otro ejemplo del usop de lanbels se ve en la implementación de los **benchmarking** dobde hemos usado ***labels:{app: my-app}*** para simplificar
el nombnre del scheduler personaizado en los comandos kubernetes. Esto nos permite:

- Identificar fácilmente los recursos de nuestro scheduler personalizado sin depender de nombres específicos

- Simplificar los comandos kubectl en nuestro script

- Hacer nuestro código más mantenible y robusto frente a recreaciones de pods

```bash
# En show_scheduler_logs():
kubectl logs -n kube-system -l app=my-scheduler --tail="$tail_lines"

# En show_scheduler_events():
SCHEDULER_POD=$(kubectl get pods -n kube-system -l app=my-scheduler -o jsonpath='{.items[0].metadata.name}')

# En describe_scheduler():
pods=$(kubectl get pods -n kube-system -l app=my-scheduler -o jsonpath='{.items[*].metadata.name}')
```

### 2. Taints and tolerations Use `node.spec.taints` and `pod.spec.tolerations` to filter nodes before scoring.

En nuestro script implementamos taints y tolerations principalmente para el scheduler personalizado. Como sabemos, los 
control-planes de Kubernetes tienen taints por defecto que evitan que pods normales se ejecuten en ellos, pero nuestro 
custom scheduler necesita estar en el control-plane para acceder a los recursos del cluster. Para ello, El archivo 
**rbac-deploy.yaml** que aplicamos contiene las tolerations necesarias. Sin estas tolerations, el pod de nuestro scheduler 
quedaría en estado Pending:

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
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        effect: "NoSchedule"
      nodeSelector:
        kubernetes.io/hostname: sched-lab-control-plane
      containers:
      - name: scheduler
        image: my-py-scheduler:latest
        imagePullPolicy: Never
        args: ["--scheduler-name","my-scheduler"]
```
Vamos a generar un nuevo nodo con un tain especial y un nuevo pod que sólo se pueada asignar a ese nuevo nodo (worker).

1. Modificamos el manifiesto de creación del clsuter para añadir un nuevo nodo:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
```

2. Borrar el cluster actual y crear uno nuevo usando este manifiesto:

```bash
kind delete cluster --name sched-lab
kind create cluster --name sched-lab --config kind-config.yaml
```
3. Etiquetar los nodos como `env=prod`:
   
```bash
kubectl label node sched-lab-worker env=prod
kubectl label node sched-lab-worker2 env=prod
kubectl label node sched-lab-worker3 env=prod
```
4. Aplicar el taint en el tercer nodo (worker3) para que solo pods con la toleration adecuada puedan ejecutarse:
   
```bash
kubectl taint nodes sched-lab-worker3 example=true:NoSchedule
```
Con esto, cualquier pod que no tenga la toleration key=example, value=true, effect=NoSchedule no podrá programarse en worker3.

5. Verificar que el cluster está listo
```bash
kubectl cluster-info --context kind-sched-lab
kubectl get nodes
```
 <img width="1176" height="541" alt="image" src="https://github.com/user-attachments/assets/6041e989-733c-4080-a663-8d7eb818b538" />


Vemos que el cluster está listo con el `control plane` y los tres `workers`.

6. Construir la nueva imagen del scheduler:

```bash
docker build --no-cache -t my-py-scheduler:latest .
```

7. Cargar la imagen en Kind:

```bash
kind load docker-image my-py-scheduler:latest --name sched-lab --nodes sched-lab-control-plane
```

8. Verificar que la imagen está en el control-plane:

```bash
docker exec -it sched-lab-control-plane crictl images | grep my-py-scheduler
```
 <img width="1174" height="516" alt="image" src="https://github.com/user-attachments/assets/5cf2683f-426e-45be-999c-b4dcc9ecfee3" />

Comprobamos que la imagen de mi `my-py-scheduler`está en el `control plane` cargada.

9. Crear namespace para pruebas:

```bash
kubectl create namespace test-scheduler
```

10.  Desplegar el scheduler custom solo en control-plane

```bash
kubectl apply -f rbac-deploy.yaml
kubectl get deployment -n kube-system
kubectl get pods -n kube-system
```
 <img width="1217" height="494" alt="image" src="https://github.com/user-attachments/assets/7bab9175-3cc3-432a-8da1-92f8a1fa62f6" />


Vemos que tenemos cargado el `my-scheduler` en el `control plane`.

11. Aplicar pods de prueba:

```bash
kubectl apply -f test-pod.yaml -n test-scheduler       
kubectl apply -f test-nginx-pod.yaml -n test-scheduler
kubectl apply -f test-worker3-pod.yaml -n test-scheduler  
```

12. Ver estado de los pods:

```bash
kubectl get pods -n test-scheduler -o wide
```

14. Revisar eventos del namespace:

```bash
kubectl get events -n test-scheduler --sort-by='.metadata.creationTimestamp'
```

<img width="1238" height="475" alt="image" src="https://github.com/user-attachments/assets/fc091052-548a-4f89-9891-70b144171c30" />

Cómo hemos etiquetado todos los nodos con el label `env=prod`, se le puede asignar un pod a cualqueir nodo. Pero vemos que el pod `test-worker3-pod`, que es el quien tiene el tolerations del `worker3`, se asigna sólo al `worker3`.

<img width="875" height="801" alt="image" src="https://github.com/user-attachments/assets/6034b386-4bcd-4e46-b2bb-5afbd7950736" />

En esta ocasión vemos cómo los dos pods sin tolerations se asignan al nodo `sched-lab-worker` y el pod con tolerations al nodo `sched-lab-worker3`. Eto es así, porque esta vez el nodo `sched-lab-worker`no tiene el label `env=prod`. Y el nodo `sched-lab-worker3` tiene tanto el label como el taint que impide que los pods sin tolerations puedan ser asignados a este nodo.

### 3. Backoff / Retry Use exponential backoff when binding fails due to transient API errors.

En la actulidad nuestra función de bind utiliza una estrategia lineal de reintentos. En concreto, esperamos siempre un delay de 2 segundos, por defecto, entre reintentos:  `time.sleep(delay)` 

```python
def bind_pod(api, pod, node_name: str, retries=3, delay=2):
    for attempt in range(1, retries + 1):
        print(f"[scheduler] Intentando bind (intento {attempt}): {pod.metadata.namespace}/{pod.me
tadata.name} -> {node_name}")
        try:
            target = client.V1ObjectReference(kind="Node", name=node_name)
            meta = client.V1ObjectMeta(name=pod.metadata.name)
            body = client.V1Binding(target=target, metadata=meta)
            api.create_namespaced_binding(pod.metadata.namespace, body, _preload_content=False)
            print(f"[scheduler] Bound {pod.metadata.namespace}/{pod.metadata.name} -> {node_name}
")
            return True
        except client.rest.ApiException as e:
            print(f"[scheduler] Failed binding pod {pod.metadata.name}: {e}")
            time.sleep(delay)
    print(f"[error] No se pudo bindear {pod.metadata.name} después de {retries} intentos")
    return False
```

Nos piden que la estretegia sea `exponencial backoff`, lo que implica que cada intento espera más que el anterior, generalmente multiplicando por 2:

1er intento → espera 1 s

2º intento → espera 2 s

3º intento → espera 4 s

4º intento → espera 8 s

Para conseguirlo creamos una función que nos proporciona ese proceso y la integramos dentro de nuestra función `bind_pod`:


```python
def exponential_backoff(attempt, base_delay=1):
    expo = base_delay * (2 ** (attempt - 1))
    jitter = random.uniform(0, expo * 0.1)
    sleep_time = expo + jitter
    print(f"[retry] Esperando {sleep_time:.2f}s antes del retry…")
    return sleep_time

def bind_pod(api, pod, node_name: str, retries=3, delay=2):
    for attempt in range(1, retries + 1):
        print(f"[scheduler] Intentando bind (intento {attempt}): {pod.metadata.namespace}/{pod.me
tadata.name} -> {node_name}")
        try:
            target = client.V1ObjectReference(kind="Node", name=node_name)
            meta = client.V1ObjectMeta(name=pod.metadata.name)
            body = client.V1Binding(target=target, metadata=meta)
            api.create_namespaced_binding(pod.metadata.namespace, body, _preload_content=False)
            print(f"[scheduler] Bound {pod.metadata.namespace}/{pod.metadata.name} -> {node_name}
")
            return True
        except client.rest.ApiException as e:
            print(f"[scheduler] Failed binding pod {pod.metadata.name}: {e}")
            sleep_delay = exponential_backoff(attempt, base_delay=2)
              
            time.sleep(sleep_delay)
    print(f"[error] No se pudo bindear {pod.metadata.name} después de {retries} intentos")
    return False
```
Notar que añadimos una distribución para evitar que todos los pods reintenten en el mismo instante, lo que previene el llamado `thundering herd`, donde múltiples pods provocarían una sobrecarga simultánea sobre el API Server. Para conseguirlo creamos una función dedicada al cálculo de ese retardo y la integramos en la función bind_pod para que cada intento utilice un tiempo de espera distinto y progresivo.

### Referencias sobre backoff exponencial y jitter

Para entender mejor por qué usamos un mecanismo de **backoff exponencial con jitter** en nuestro scheduler, puedes consultar estas lecturas recomendadas:

- *Understanding Jitter Backoff – A Beginner’s Guide* — explica de forma muy clara qué es el **jitter**, cómo se combina con el backoff exponencial y por qué es útil para evitar que muchos reintentos coincidan exactamente.  
  https://dev.to/biomousavi/understanding-jitter-backoff-a-beginners-guide-2gc  

- *CrashLoopBackOff* en Kubernetes — describe cómo Kubernetes utiliza backoff exponencial para gestionar reinicios fallidos de pods, evitando la saturación de recursos mediante esperas progresivas.  
  https://www.perfectscale.io/blog/kubernetes-errors#:~:text=CrashLoopBackOff%20means%20that%20a%20Kubernetes,max%2C%20to%20reduce%20resource%20thrashing.

- *Thundering herd problem* — artículo de Wikipedia que explica cómo una gran cantidad de procesos puede reintentar al mismo tiempo y saturar un recurso compartido, motivo por el cual usamos jitter para dispersar los reintentos.  
  https://en.wikipedia.org/wiki/Thundering_herd_problem


#### Implementación en los scripts de prueba

Aunque se nos pide que se implemente dentro del código scheduler.py. Durante la implementación de los bechmarking también hemos usado un backoff simple con sleep entre intentos:

- **En la creación de pods**:

```bash
create_single_pod() {
    local pod_name=$1
    local attempt=0
    local max_attempts=3  # ← Máximo de reintentos configurado por nosotros
    
    while [ $attempt -lt $max_attempts ]; do
        # Intentamos crear el pod
        if kubectl apply -n "$NAMESPACE" -f - >/dev/null 2>&1; then
            # Esperamos con backoff implícito
            local wait_attempt=0
            while [ $wait_attempt -lt 10 ]; do
                if kubectl get pod "$pod_name" -n "$NAMESPACE" >/dev/null 2>&1; then
                    return 0
                fi
                sleep 1  # ← Espera entre verificaciones
                ((wait_attempt++))
            done
        fi
        attempt=$((attempt + 1))
        sleep 2  # ← Backoff simple entre reintentos
    done
}
```

- **En la creación del cluster**:

```bash
create_kind_cluster() {
    local retries=3      # ← Reintentos configurados por nosotros
    local attempt=1

    while [[ $attempt -le $retries ]]; do
        if kind create cluster --name "$cluster" --config "$config_file"; then
            return 0
        else
            echo "Reintentando creación del cluster ($attempt/$retries)..."
        fi
        ((attempt++))
        sleep 2  # ← Backoff entre reintentos
    done
    return 1
}
```
 
### 4. Spread policy Distribute similar Pods evenly across Nodes.

En este caso nos piden que se distribuya los pods en los diferntes nodos de forma equitativa intentando mejorar la disponibilidad y tolerancia a fallos. Nosotros ya teneos una distribución sencilla mediante el label `app=my-scheduler`. Lo que intenta mantener una asignación equilibrada entre los nodos disponibles, en lugar de concentrarlos todos en el mismo nodo.

```python
def choose_node(api, pod):
    nodes = [n for n in api.list_node().items if is_node_compatible(n, pod)]
    if not nodes:
        return None  # No hay nodos compatibles → pod rechazado

    pods = api.list_pod_for_all_namespaces().items
    node_load = {n.metadata.name: 0 for n in nodes}

    pod_app_label = pod.metadata.labels.get("app") if pod.metadata.labels else None
    for p in pods:
        if p.spec.node_name in node_load:
            if not pod_app_label or (p.metadata.labels and p.metadata.labels.get("app") == pod_ap
p_label):
                node_load[p.spec.node_name] += 1

    node = min(node_load, key=node_load.get)
    print(f"[policy] Nodo elegido para {pod.metadata.name}: {node}")
    return node
```

En desarrollos profesionales y robustos, el concepto de `spread policy` se relaciona directamente con la **topología de los nodos**, es decir, cómo se organizan los nodos en distintas zonas, racks o regiones dentro del cluster. La idea es distribuir los pods de manera equilibrada **teniendo en cuenta tanto el número de pods por nodo como atributos topológicos** como `zone`, `rack` o `region`, para mejorar la disponibilidad y tolerancia a fallos ante caídas parciales de la infraestructura. Kubernetes proporciona para ello los **Topology Spread Constraints**, que permiten definir reglas declarativas de distribución de pods sobre diferentes topologías, asegurando que pods similares no se concentren en un solo nodo o zona. Referencias útiles: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/ | https://dev.to/farshad_nick/understanding-pod-topology-spread-constraints-in-kubernetes-5e8e


#### Implementación en los scripts de pruebas

Del mismo modo, implementamos una política de distribución mediante round-robin en nuestro script. Se puede ver en la función ***load_pods_from_yaml*** del script **bechmarking_2/start.sh**:

```bash
 load_pods_from_yaml() {
    local -n DIRS=$1
    local total_pods=$2
    local mode=${3:-s}
    local parallel=${4:-1}

    local counter=0 batch pod_yaml

    echo "Creando $total_pods pods desde YAML ($mode, $parallel en paralelo)..."

    while [[ $counter -lt $total_pods ]]; do
        batch=$(( total_pods - counter < parallel ? total_pods - counter : parallel ))

        for ((i=1;i<=batch;i++)); do
            dir_index=$(( (counter + i - 1) % ${#DIRS[@]} ))
            pod_yaml="${DIRS[$dir_index]}/${DIRS[$dir_index]}-pod.yaml"

            if [[ ! -f "$pod_yaml" ]]; then
                warn "Archivo $pod_yaml no existe, se omite"
                continue
            fi
            pids=()
            if grep -q 'generateName:' "$pod_yaml"; then
                info "Creando pod desde $pod_yaml con generateName..."
                if [[ "$mode" == "p" ]]; then
                    kubectl create -f "$pod_yaml" &
                    pids+=($!)
                else
                    kubectl create -f "$pod_yaml"
                fi
            else
                info "Creando pod desde $pod_yaml con nombre fijo..."
                if [[ "$mode" == "p" ]]; then
                    kubectl apply -f "$pod_yaml" &
                    pids+=($!)
                else
                    kubectl apply -f "$pod_yaml"
                fi
            fi
        done

        [[ "$mode" == "p" ]] && wait "${pids[@]}"
        counter=$((counter + batch))
    done

    echo "Todos los pods creados desde YAML."
}
```


### ✅ **Checkpoint 5:**
***Demonstrate your extended policy via pod logs and placement.***

En los apartadoas anteriores se mmuestran diferntes capturas de pantalla donde se muestra la funcionalidad pedida ee implementada dentro del scheduler personalizado tipo watch.

- [Label-based node filtering](https://github.com/jogugil/jogugil-py-scheduler-repo.o/blob/main/Practica_Group.md#1-label-based-node-filtering)
- [Taints and tolerations](#2-taints-and-tolerations-use-nodespectaints-and-podspectolerations-to-filter-nodes-before-scoring)
- [Backoff / Retry](#3-backoff--retry-use-exponential-backoff-when-binding-fails-due-to-transient-api-errors)
- [Spread policy](#spread-policy-distribute-similar-pods-evenly-across-nodes)


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

