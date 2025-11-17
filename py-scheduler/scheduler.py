import argparse
import time
from kubernetes import client, config, watch
import signal

running = True

# Handler para Ctrl+C o SIGTERM
def signal_handler(sig, frame):
    global running
    print("[info] Señal de terminación recibida, deteniendo scheduler...")
    running = False

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# Cargar cliente Kubernetes
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

# Comprobar si nodo es compatible con tolerations del pod
def is_node_compatible(node, pod):
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

# Elegir nodo según menor carga y compatibilidad
def choose_node(api, pod):
    nodes = [n for n in api.list_node().items
             if n.metadata.labels and n.metadata.labels.get("env") == pod.metadata.labels.get("env")
             and is_node_compatible(n, pod)]
    if not nodes:
        raise RuntimeError("No hay nodos disponibles compatibles")

    pods = api.list_pod_for_all_namespaces().items
    node_load = {n.metadata.name: 0 for n in nodes}

    # Contar solo Pods del mismo app para balance
    pod_app_label = pod.metadata.labels.get("app") if pod.metadata.labels else None
    for p in pods:
        if p.spec.node_name in node_load:
            if not pod_app_label or (p.metadata.labels and p.metadata.labels.get("app") == pod_app_label):
                node_load[p.spec.node_name] += 1

    node = min(node_load, key=node_load.get)
    print(f"[policy] Nodo elegido para {pod.metadata.name}: {node}")
    return node

# Bind de pod a nodo con retry
def bind_pod(api, pod, node_name: str, retries=3, delay=2):
    for attempt in range(1, retries + 1):
        print(f"[scheduler] Intentando bind (intento {attempt}): {pod.metadata.namespace}/{pod.metadata.name} -> {node_name}")
        try:
            target = client.V1ObjectReference(kind="Node", name=node_name)
            meta = client.V1ObjectMeta(name=pod.metadata.name)
            body = client.V1Binding(target=target, metadata=meta)
            api.create_namespaced_binding(pod.metadata.namespace, body, _preload_content=False)
            print(f"[scheduler] Bound {pod.metadata.namespace}/{pod.metadata.name} -> {node_name}")
            return True
        except client.rest.ApiException as e:
            print(f"[scheduler] Failed binding pod {pod.metadata.name}: {e}")
            time.sleep(delay)
    print(f"[error] No se pudo bindear {pod.metadata.name} después de {retries} intentos")
    return False

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
                # Detectar pod pendiente con scheduler custom
                if (pod.status.phase == "Pending" and
                      pod.spec.scheduler_name == args.scheduler_name and
                                   not pod.spec.node_name):

                    record_trace(pod, "ADDED")

                    try:
                        # Intentar elegir nodo compatible
                        node = choose_node(api, pod)
                        if bind_pod(api, pod, node):
                            record_trace(pod, "BOUND")
                            print(f"[success] {pod.metadata.namespace}/{pod.metadata.name} -> {node}")
                        else:
                            print(f"[failure] {pod.metadata.namespace}/{pod.metadata.name} no se pudo programar")
                    except RuntimeError as e:
                        # No hay nodos compatibles → reasignar scheduler default
                        print(f"[warn] No hay nodos compatibles para {pod.metadata.name}, reasignando scheduler default")
                        body = {"spec": {"schedulerName": None}}
                        try:
                            api.patch_namespaced_pod(pod.metadata.name, pod.metadata.namespace, body)
                            print(f"[info] Pod {pod.metadata.name} reasignado al scheduler default")
                        except client.rest.ApiException as patch_e:
                            print(f"[error] No se pudo reasignar scheduler de {pod.metadata.name}: {patch_e}")
        except Exception as e:
            print(f"[error] Error al programar {pod.metadata.name}: {e}")

if __name__ == "__main__":
    main()
