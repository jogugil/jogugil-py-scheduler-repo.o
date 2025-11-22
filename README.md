
## Autores

- **José Javier Gutiérrez Gil** ([jogugil@gmail.com]) – Colaborador

**Nota:** 
*La resolución de todos los puntos de la práctica se describen en  [Practica_group.md](Practica_Group.md).*

Tenemos la sguiente estructura:
    

## Licencias

[![Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0)
Código fuente bajo **Apache License 2.0**

[![CC BY-NC 4.0](https://img.shields.io/badge/License-CC%20BY--NC%204.0-lightgrey.svg)](https://creativecommons.org/licenses/b>
Documentación, PDFs e imágenes bajo **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)**
#
#

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

- **jogugil** (jogugil@gmail.com) - José Javier Gutiérrez Gil  

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

Antes de empezar, debemos tener instalados los prerequisitos: **kind**, **kubectl** y **Docker**.

**Note:** *The development of the practice and the results obtained are described in [Practica_group.md](Practica_Group.md).*

### A) Construcción del entorno de trabajo

#### a) Actualizar el sistema

```bash
# Actualizamos los paquetes del sistema
sudo apt update && sudo apt upgrade -y
```
#### b) Instalamos Docker

Docker nos permite construir las imágenes que luego importaremos a nbuestro cluster usando kind (clúster ligero alternativo).

```bash
# Instalamos dependencias necesarias
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

# Añadimos el repositorio oficial de Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Instalamos Docker Engine
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# Verificamos que Docker funcione correctamente
sudo systemctl enable docker
sudo systemctl start docker
docker --version

```

#### Nota: podemos añadir nuestro usuario al grupo docker para no usar sudo
```bash
sudo usermod -aG docker $USER
newgrp docke
```

#### c) Instalamos kubectl

Instalamos kubectl globalmente para usarlo con kind.

```bash
# Descargamos la versión estable de kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Le damos permisos de ejecución
chmod +x kubectl

# Lo movemos a un directorio en el PATH
sudo mv kubectl /usr/local/bin/

# Verificamos la instalación
kubectl version --client
```


#### d) Instalamos kind (Kubernetes IN Docker)

Kind nos permitirá levantar clústeres de Kubernetes dentro de contenedores Docker, útil para probar nuestro scheduler en entornos aislados o de CI/CD.
```bash
# Descargamos la versión estable de kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/stable/linux-amd64/kind

# Le damos permisos de ejecución
chmod +x ./kind

# Movemos el binario al PATH
sudo mv ./kind /usr/local/bin/kind

# Verificamos la instalación
kind version
```
#### e) Verificamos el entorno Kubernetes

Una vez configurado todo, comprobamos que esté tofo funcionando correctamente y que kubectl pueda comunicarse con él.

```bash
kind --version
kubectl version --client
kind help
kubectl help
```
### B) Ejecución de la práctica


Una ves tenemos el entorno isntalado, podemos comenzar con las pruebas que nso piden. En este proyecto disponemos de un `Makefile` que automatiza los pasos principales de construcción, despliegue y pruebas de nuestro scheduler personalizado en Kubernetes. Cada comando `make` corresponde a una regla del `Makefile` que ejecuta varias tareas automáticamente.

### Pasos

0) **Prerequisitos**  
   Asegúrate de tener instalados los siguientes programas (visto con antelación):
   - Docker (para construir imágenes de los schedulers)  
   - kind (Kubernetes IN Docker, para crear clústeres locales)  
   - kubectl (cliente de Kubernetes para aplicar recursos y ver logs)

1) **Crear el clúster kind**  
   Creamos un clúster local de Kubernetes llamado `sched-lab` donde desplegaremos los schedulers.
   ```bash
   kind create cluster --name sched-lab
   kubectl cluster-info
   kubectl get nodes

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
El `Makefile`que contiene las reglas a ejecutar es:
```bash
APP=my-py-scheduler
KIND_CLUSTER=sched-lab

.PHONY: build kind-load deploy test logs undeploy

build:
        docker build -t $(APP):latest .

kind-load:
        kind load docker-image $(APP):latest --name $(KIND_CLUSTER)

deploy:
        kubectl apply -f rbac-deploy.yaml

test:
        kubectl apply -f test-pod.yaml

logs:
        kubectl -n kube-system logs deploy/my-scheduler -f

undeploy:
        kubectl delete -f rbac-deploy.yaml --ignore-not-found
        kubectl delete -f test-pod.yaml --ignore-not-found
```

## Local run (optional)
```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python scheduler.py --scheduler-name my-scheduler --kubeconfig ~/.kube/config
```
