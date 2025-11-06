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
        a. Obtiene la lista completa de nodos: `nodes = api.list_node().items`
        b. Cuenta cuántos Pods están ya asignados a cada nodo: `cnt = sum(1 for p in pods if p.spec.node_name == n.metadata.name)`
        c. Selecciona el nodo con menos Pods, aplicando así una estrategia sencilla de “menor carga”: `if cnt < min_cnt:`
 
   ✅ 3. Actuar: realizar el binding del Podç
    ```python
   bind_pod(api, pod, node_name)
    ```
El binding consiste en:
    a) crear una referencia al nodo: `target = client.V1ObjectReference(kind="Node", name=node_name)`
    b) crear la estructura V1Binding: `body = client.V1Binding(target=target, metadata=client.V1ObjectMeta(name=pod.metadata.name))`
    c) enviarla al API Server para completar la asignación: `api.create_namespaced_binding(pod.metadata.namespace, body)`

Este paso actualiza el campo .spec.nodeName del Pod.  Y a partir de aquí, el kubelet del nodo asignado detecta la nueva asignación y comienza la creación del contenedor correspondiente.
    
## 🐳🔐🧪 Step 4 5 y 6 — Build and Deploy. RBAC & Deployment. Test Your Scheduler


### ✅**Checkpoint 3:**

***Your scheduler should log a message like:***
    - Bound default/test-pod -> kind-control-plane

## 🧩 Step 7 — Event-Driven Scheduler (Watch API)

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

