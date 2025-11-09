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
