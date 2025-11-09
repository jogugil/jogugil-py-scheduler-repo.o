import argparse, time, math
from kubernetes import client, config

def load_client(kubeconfig=None):
    if kubeconfig:
        config.load_kube_config(kubeconfig)
    else:
        config.load_incluster_config()
    return client.CoreV1Api()

def bind_pod(api: client.CoreV1Api, pod, node_name: str):
    print(f"[scheduler] Attempting bind: {pod.metadata.namespace}/{pod.metadata.name} ->
{node_name}")    
    try:
        target = client.V1ObjectReference(kind="Node", name=node_name)
        meta = client.V1ObjectMeta(name=pod.metadata.name)
        body = client.V1Binding(target=target, metadata=meta)
        api.create_namespaced_binding(pod.metadata.namespace, body, _preload_content=False)
    except Exception as e:
        import traceback
        traceback.print_exc()
        print("ERROR DETALLADO:", repr(e))
    print(f"[scheduler] Bound {pod.metadata.namespace}/{pod.metadata.name} -> {node_name}
")     
def choose_node(api: client.CoreV1Api, pod) -> str:
    print(f"[scheduler] LIST nodes")
    nodes = api.list_node().items

    print(f"[scheduler] LIST all pods to compute node load")
    pods = api.list_pod_for_all_namespaces().items

    print(f"[scheduler] Processing pod: {pod.metadata.name}")

    if not nodes:
        raise RuntimeError("No nodes available")

    min_cnt = math.inf
    pick = nodes[0].metadata.name
    for n in nodes:
        cnt = sum(1 for p in pods if p.spec.node_name == n.metadata.name)
        print(f"[scheduler] Node {n.metadata.name} currently has {cnt} pods")
        if cnt < min_cnt:
            min_cnt = cnt
            pick = n.metadata.name

    print(f"[scheduler] Selected node {pick} for pod {pod.metadata.name}")
    return pick

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scheduler-name", default="my-scheduler")
    parser.add_argument("--kubeconfig", default=None)
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()

    api = load_client(args.kubeconfig)
    print(f"[polling] scheduler starting… name={args.scheduler_name}")

    while True:
        print("[scheduler] LIST pods pending scheduling")
        pods = api.list_pod_for_all_namespaces(field_selector="spec.nodeName=").items

        for pod in pods:
            if pod.spec.scheduler_name != args.scheduler_name:
                continue

            try:
                print(f"[scheduler] Attempting to schedule pod: {pod.metadata.namespace}/
{pod.metadata.name}")

                node = choose_node(api, pod)

                bind_pod(api, pod, node)

            except Exception as e:
                print(f"[scheduler] retry scheduling pod due to error: {e}")

        time.sleep(args.interval)

if __name__ == "__main__":
    main()
