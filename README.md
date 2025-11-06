# Custom Kubernetes Scheduler
## Entrega pácticas Asignatura Cloud Computing (CC) - M.U. Computación en la Nube y Altas prestaciones

This repository provides a minimal custom scheduler written in **Python** using the
`kubernetes` Python client. It includes three variants:

- **main (polling)**: simple polling loop that finds Pending pods and binds them.
- **(watch-based)**: skeleton using the watch stream with TODOs.

Use `scripts/init_branches.sh` to create Git branches locally: `main`, `student`, `solution`, or use
your own approach for that.

## Repository Branch Initialization

For this project, we did **not** use the original `init_branches.sh` script. Instead, we manually created the repository on GitHub and configured it for our group workflow.

### Repository

- HTTPS URL: [https://github.com/jogugil/jogugil-py-scheduler-repo.o](https://github.com/jogugil/jogugil-py-scheduler-repo.o)  
- SSH URL: `git@github.com:jogugil/jogugil-py-scheduler-repo.o.git`

### Group Members

- **JavierDiazL** ()  
- **Francesc** ()
- - **jogugil** (jogugil@gmail.com) - José Javier Gutiérrez Gil  

All members are collaborators of the repository on GitHub.

### Script adapted for our repository

We modified the original script to work with our repository structure and reflect the group collaboration. This new script is called `scripts/init_branches_group.sh` and is used to create the following branches locally:

- `main` → polling version of the scheduler  
- `student` → watch skeleton  
- `solution` → full watch scheduler  

The script copies the appropriate files into each branch and makes the corresponding commits.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Base repository directory
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# Initialize Git if necessary
if [ ! -d .git ]; then
  git init
  git add -A
  git commit -m "Initial: common Python files"
fi

# main: polling
git checkout -B main
cp -f variants/polling/scheduler.py ./scheduler.py
git add scheduler.py
git commit -m "main: polling scheduler (Python)"

# student: watch skeleton
git checkout -B student
cp -f variants/watch-skeleton/scheduler.py ./scheduler.py
git add scheduler.py
git commit -m "student: watch skeleton scheduler (Python)"

# solution: watch solution
git checkout -B solution
cp -f variants/watch-solution/scheduler.py ./scheduler.py
git add scheduler.py
git commit -m "solution: watch-based scheduler (Python)"

# Return to main at the end
git checkout main

echo "Branches created for group repository: main (polling), student (watch skeleton), solution (watch solution)"
```
## Quickstart

```bash
# 0) Prereqs
#    kind, kubectl, Docker

# 1) Create a kind cluster
kind create cluster --name sched-lab

# 2) Build & load image
make build
make kind-load

# 3) Deploy ServiceAccount/RBAC + Deployment
make deploy

# 4) Schedule a test Pod using your scheduler
make test

# 5) Watch logs for binding output
make logs
```

Cleanup:
```bash
make undeploy
kind delete cluster --name sched-lab
```

## Local run (optional)
```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python scheduler.py --scheduler-name my-scheduler --kubeconfig ~/.kube/config
```
