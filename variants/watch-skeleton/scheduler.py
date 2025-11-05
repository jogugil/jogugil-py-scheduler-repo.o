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
