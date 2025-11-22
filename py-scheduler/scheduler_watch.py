import argparse
import time
import datetime
from kubernetes import client, config, watch
import signal
import random
import json
import os

running = True
REJECTION_LABEL = "scheduler-rejected"
REJECTION_TIMEOUT = 300  # segundos de ignorar un pod

# -------------------------
# Señales
# -------------------------
def signal_handler(sig, frame):
    global running
    print("[INFO] Señal de terminación recibida, deteniendo scheduler…")
    running = False

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# -------------------------
# Evento de trazas
# -------------------------
EVENTS = {}

def record_trace(pod, event_type, timestamp=None):
    """ De momento sólo guardamos el tiempo del máximo de lso contenedores que posee el pod.
         se podría usar:

        if "started" not in EVENTS[key] or EVENTS[key]["started"] is None:
            EVENTS[key]["started"] = []

        started_times = [
            c.state.running.started_at.timestamp()
            for c in container_statuses
            if c.state.running
        ]

        if started_times:
            EVENTS[key]["started"].extend(started_times)
            print(f"[EVENT] type=STARTED pod={key} ts={started_times}")
    """

    ts = timestamp or time.time()
    key = f"{pod.metadata.namespace}/{pod.metadata.name}"

    if key not in EVENTS:
        EVENTS[key] = {
            "created": None,
            "added": pod.metadata.creation_timestamp.timestamp(),
            "scheduled": None,
            "bound": None,
            "started": None
        }
    et = event_type.lower()


    if et in ("created", "added", "scheduled", "bound"):
        EVENTS[key][et] = ts
        print(f"[EVENT] {key}: {event_type.upper()} detectado a {ts}")
        # Calcular latencia automáticamente si es BOUND
        if et == "bound":
            added_ts = EVENTS[key].get("added")
            if added_ts:
                latency = ts - added_ts
                print(f"[EVENT]  ADDED {key} ts={added_ts}")
                print(f"[LATENCY] {key}: ADDED -> BOUND = {latency:.2f}s")
        return

    print(f"[EVENT] {event_type}: {key} at {ts}")

    if event_type == "started":
        container_statuses = pod.status.container_statuses or []
        if not container_statuses:
            print(f"[EVENT] type=STARTED pod={key} ts=none_no_container_status")
            return
        # Evitar sobreescritura accidental
        if EVENTS[key]["started"] is not None:
            return

        started_times = [
            c.state.running.started_at.timestamp()
            for c in container_statuses
            if c.state.running
        ]
        if started_times:
            EVENTS[key]["started"] = max(started_times)
            print(f"[EVENT] type=STARTED pod={key} ts={EVENTS[key]['started']}")
# -------------------------
# Rechazo de pods
# -------------------------
def pod_recently_rejected(pod):
    print(f"[DEBUG] Comprobando rechazo reciente del pod {pod.metadata.name}")

    if pod.metadata.annotations and REJECTION_LABEL in pod.metadata.annotations:
        ts_str = pod.metadata.annotations[REJECTION_LABEL]
        ts = datetime.datetime.fromisoformat(ts_str)
        now = datetime.datetime.utcnow()
        time_diff = (now - ts).total_seconds()

        print(f"[DEBUG] Pod fue rechazado anteriormente: {ts_str}")
        print(f"[DEBUG] Tiempo desde rechazo: {time_diff:.1f}s (timeout={REJECTION_TIMEOUT}s)")
        print(f"[DEBUG] Estado rechazo: {time_diff < REJECTION_TIMEOUT}")

        return time_diff < REJECTION_TIMEOUT

    print(f"[DEBUG] Pod {pod.metadata.name} no tiene anotación de rechazo")
    return False


def mark_pod_rejected(api, pod):
    print(f"[DEBUG] Marcando pod como rechazado: {pod.metadata.name}")

    if not pod.metadata.annotations:
        pod.metadata.annotations = {}
        print("[DEBUG] Inicializando anotaciones vacías")

    rejection_timestamp = datetime.datetime.utcnow().isoformat()
    pod.metadata.annotations[REJECTION_LABEL] = rejection_timestamp
    print(f"[DEBUG] Guardado timestamp de rechazo: {rejection_timestamp}")

    body = {"metadata": {"annotations": pod.metadata.annotations}}
    print(f"[DEBUG] PATCH body: {body}")

    try:
        api.patch_namespaced_pod(pod.metadata.name, pod.metadata.namespace, body)
        print(f"[INFO] Pod {pod.metadata.name} marcado como rechazado")
    except Exception as e:
        print(f"[ERROR] Error aplicando rechazo al pod {pod.metadata.name}: {e}")
        raise

# -------------------------
# Cliente Kubernetes
# -------------------------
def load_client(kubeconfig=None):
    try:
        if kubeconfig:
            print("[CONFIG] Cargando kubeconfig local…")
            config.load_kube_config(config_file=kubeconfig)
        else:
            print("[CONFIG] Cargando configuración en cluster…")
            config.load_incluster_config()
    except Exception as e:
        raise RuntimeError(f"Error al cargar configuración: {e}")

    return client.CoreV1Api()

# -------------------------
# Compatibilidad de nodos
# -------------------------
def is_node_compatible(node, pod):
    print(f"[DEBUG] Verificando compatibilidad pod={pod.metadata.name} nodo={node.metadata.name}")

    node_env = node.metadata.labels.get("env") if node.metadata.labels else None

    if node_env != "prod":
        print(f"[DEBUG] Nodo {node.metadata.name} rechazado: env != prod")
        return False
    
    print(f"[DEBUG] Nodo {node.metadata.name} tiene env=prod")

    node_taints = node.spec.taints or []
    pod_tolerations = pod.spec.tolerations or []

    if not node_taints:
        return True

    for taint in node_taints:
        tolerated = False
        print(f"[DEBUG] Revisando taint: {taint.key}={getattr(taint, 'value', None)}:{taint.effect}")

        for tol in pod_tolerations:
            print(f"[DEBUG] Comparando toleration: {tol.key}={getattr(tol, 'value', None)}:{tol.effect}")

            if tol.key != taint.key:
                continue

            if tol.effect != taint.effect:
                continue

            operator = tol.operator if tol.operator else "Equal"

            if operator == "Exists":
                tolerated = True
                break

            if operator == "Equal" and getattr(tol, "value", None) == getattr(taint, "value", None):
                tolerated = True
                break

        if not tolerated:
            print(f"[DEBUG] Nodo {node.metadata.name} no tolera el taint {taint.key}")
            return False

    print(f"[DEBUG] Nodo {node.metadata.name} compatible")
    return True

# -------------------------
# Selección de nodo
# -------------------------
def choose_node(api, pod):
    print(f"[DEBUG] Seleccionando nodo para pod {pod.metadata.name}")

    all_nodes = api.list_node().items
    nodes = [n for n in all_nodes if is_node_compatible(n, pod)]

    if not nodes:
        return None

    pods = api.list_pod_for_all_namespaces().items
    node_load = {n.metadata.name: 0 for n in nodes}

    pod_app_label = pod.metadata.labels.get("app") if pod.metadata.labels else None

    for p in pods:
        if p.spec.node_name in node_load:
            if not pod_app_label or (p.metadata.labels and p.metadata.labels.get("app") == pod_app_label):
                node_load[p.spec.node_name] += 1
                print(f"[DEBUG] Nodo {p.spec.node_name} carga={node_load[p.spec.node_name]}")

    node = min(node_load, key=node_load.get)
    print(f"[POLICY] Nodo elegido: {node} (carga={node_load[node]})")
    print(f"[LIST-OP] Nodo {node} tiene {node_load[node]} pods activos")
    return node

# -------------------------
# Bind del pod
# -------------------------
def bind_pod(api, pod, node_name, retries=3, delay=2):
    key = f"{pod.metadata.namespace}/{pod.metadata.name}"

    if key not in EVENTS:
        EVENTS[key] = {"added": None, "scheduled": None, "bound": None, "started": None, "bind_attempts": 0}

    for attempt in range(1, retries + 1):
        EVENTS[key]["bind_attempts"] = attempt
        print(f"[SCHED] Intento bind {attempt}: {key} -> {node_name}")

        try:
            target = client.V1ObjectReference(kind="Node", name=node_name)
            meta = client.V1ObjectMeta(name=pod.metadata.name)
            body = client.V1Binding(target=target, metadata=meta)

            api.create_namespaced_binding(pod.metadata.namespace, body, _preload_content=False)
            print(f"[INFO] Bind correcto: {key} -> {node_name}")
            return True

        except client.rest.ApiException as e:
            print(f"[ERROR] Fallo bind {key}: {e}")
            time.sleep(delay)

    print(f"[ERROR] No se pudo bindear {pod.metadata.name} después de {retries} intentos")
    return False

# -------------------------
# WATCH principal
# -------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scheduler-name", default="my-scheduler")
    parser.add_argument("--kubeconfig", default=None)
    args = parser.parse_args()

    api = load_client(args.kubeconfig)
    print(f"[INFO] Scheduler iniciado: {args.scheduler_name}")

    w = watch.Watch()

    while running:
        try:
            for event in w.stream(api.list_pod_for_all_namespaces, timeout_seconds=60):
                pod = event["object"]
                event_type = event["type"] # ADDED, MODIFIED, DELETED

                if not running:
                    break

                if not pod or not hasattr(pod, "spec"):
                    continue

                print(f"[DEBUG] Evento: {event_type} pod={pod.metadata.name}")
                print(f"Attempting to schedule pod: {pod.metadata.namespace}/{pod.metadata.name}")
                if pod.spec.node_name:
                    print(f"[INFO] Pod ya asignado - nodo={pod.spec.node_name} fase={pod.status.phase}")
                    if pod.status.phase == "Running":
                        record_trace(pod, "STARTED")
                    continue

                if event_type in ("ADDED", "MODIFIED"):
                    if pod_recently_rejected(pod):
                        continue
                    key = f"{pod.metadata.namespace}/{pod.metadata.name}"
                    
                    if event_type == "ADDED":
                        record_trace(pod, "CREATED")
                        print(f"[EVENT] {key}: CREATED detectado")
                    elif event_type == "MODIFIED":
                        if pod.status.phase == "Running":
                            record_trace(pod, "STARTED")

                    if pod.status.phase == "Pending" and pod.spec.scheduler_name == args.scheduler_name and not pod.spec.node_name:
                        record_trace(pod, "ADDED")
                        print(f"[EVENT] {key}: ADDED detectado")

                    print(f"[SCHED] Procesando pod {pod.metadata.namespace}/{pod.metadata.name}")
                    print(f"[DEBUG] schedulerName={pod.spec.scheduler_name}")
                    print(f"[DEBUG] phase={pod.status.phase}")
                    print(f"[DEBUG] anotaciones={pod.metadata.annotations}")

                    if pod_recently_rejected(pod):
                        print(f"[INFO] Pod {pod.metadata.name} saltado (rechazo reciente)")
                        continue

                    node = choose_node(api, pod)
                    if node:
                        record_trace(pod, "SCHEDULED")
                        ts_iso = datetime.datetime.utcnow().isoformat()
                        print(f"[BIND-TIME] {pod.metadata.namespace}/{pod.metadata.name} {ts_iso}")
                        if bind_pod(api, pod, node):
                            record_trace(pod, "BOUND")
                            print(f"[INFO] Binding Pod {key} asignado a {node}")
                            print(f"[EVENT] Bound {key}: BOUND detectado")
                        else:
                            print(f"[ERROR] Bind falló para {key}")
                    else:
                        print("[INFO] No hay nodos compatibles, marcando rechazo")
                        mark_pod_rejected(api, pod)
                        print(f"[INFO] Pod {key} rechazado temporalmente")

        except Exception as e:
            print(f"[ERROR] Error general en el scheduler: {e}")

if __name__ == "__main__":
    main()
