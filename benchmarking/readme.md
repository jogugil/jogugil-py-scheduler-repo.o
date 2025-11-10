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


AÜN EN DESARROLLO Y PRUEBAS!!!!
