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
 ## Step 0 — Set up the environment
 
 We set up the environment using the required installation prerequisites. We then followed the steps described in 
 section `A` of the `README.md`.

 In the environment we prepared, we executed the first step:
 
 ## Step 1 — Observe the Default Scheduler-. 
 
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

### **Checkpoint 1:**
Describe the path:
    kubectl run → Pod created → Scheduler assigns Node → kubelet starts Pod.

