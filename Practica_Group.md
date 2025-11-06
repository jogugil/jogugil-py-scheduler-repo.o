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
  <em>Figure 2: Verification of the default scheduler and scheduling of a test Pod.</em>
</p>

✅ **Descripción del flujo de scheduling en Kubernetes**

La **Figura 2** muestra la ejecución de los comandos utilizados para verificar que el scheduler por defecto está en funcionamiento y para observar cómo se programa un Pod sencillo dentro del clúster creado con Kind. A partir de los resultados obtenidos, podemos describir el funcionamiento interno del sistema cuando programamos un Pod:

**a) Enviamos la orden de creación del Pod**  
Ejecutamos `kubectl run test --image=nginx --restart=Never`, lo que provoca que el cliente `kubectl` envíe al API Server un objeto Pod para ser creado. En este momento, el Pod se registra pero aún no tiene un nodo asignado.

**b) El Pod queda inicialmente en estado *Pending***  
Tras su creación, el API Server almacena el Pod con `status=Pending`, ya que todavía no ha sido asociado a ningún nodo del clúster.

**c) El scheduler detecta el nuevo Pod sin asignar**  
El `kube-scheduler`, que aparece ejecutándose como se muestra en la Figura 2, observa periódicamente los Pods pendientes mediante sus mecanismos internos de *informers*.  
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
## 🧠 Step 3 — Implement the Polling Scheduler
### ✅**Checkpoint 2:**

***Understand the control loop:***
    - **Observe**: *list unscheduled Pods:*    
    - **Decide**: *pick a Node*       
    - **Act**: *bind the Pod*
 
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
- ***What are the trade-offs between polling vs event-driven models?***
- ***How do taints and tolerations interact with your scheduling logic?***
- ***What are real-world policies you could implement using this framework?***
