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

Antes de empezar, debemos tener instalados los prerequisitos: **kind**, **kubectl** y **Docker**.

**Note:** *The development of the practice and the results obtained are described in [Practica_group.md](Practica_Group.md).*

### A) Construcción del entorno de trabajo

#### a) Actualizar el sistema

```bash
# Actualizamos los paquetes del sistema
sudo apt update && sudo apt upgrade -y
```
#### b) Instalar Docker

Docker nos permite construir las imágenes que luego importaremos a MicroK8s o usaremos en kind si deseamos probar en un clúster ligero alternativo.

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

#### Note: podemos añadir nuestro usuario al grupo docker para no usar sudo
```bash
sudo usermod -aG docker $USER
newgrp docke
```
#### c) Instalar MicroK8s

MicroK8s nos proporciona un clúster Kubernetes ligero, ideal para entornos locales o de desarrollo.
```bash
# Instalamos MicroK8s
sudo snap install microk8s --classic

# Añadimos nuestro usuario al grupo microk8s
sudo usermod -aG microk8s $USER
newgrp microk8s

# Verificamos el estado del clúster
microk8s status --wait-ready
```

#### d) Habilitamo los complementos necesarios en MicroK8s

Activaremos algunos módulos esenciales para ejecutar nuestro scheduler y los Pods de prueba.
```bash
# Habilitamos DNS, Dashboard y Storage
microk8s enable dns dashboard storage
```
 Nota: Con esto, el clúster tendrá resolución de nombres interna, almacenamiento persistente y un panel de control web.

#### e) Instalamos kubectl

Aunque MicroK8s ya incluye microk8s kubectl, es recomendable instalar kubectl globalmente para usarlo con MicroK8s, kind u otros clústeres.

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

Nota: Podemos crear un alias para usar el kubectl de MicroK8s por defecto:

```bash
sudo snap alias microk8s.kubectl kubectl
```

#### f) Instalar kind (Kubernetes IN Docker)

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
#### g) Verificar el entorno Kubernetes

Una vez configurado todo, comprobamos que MicroK8s esté funcionando correctamente y que kubectl pueda comunicarse con él.
```bash
microk8s status --wait-ready
microk8s kubectl get nodes
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
