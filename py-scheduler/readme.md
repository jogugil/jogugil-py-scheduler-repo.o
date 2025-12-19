Directorio de ejecución de los scripts con la copia del `scheduler.py` que se desee.
El script `scheduler-test.sh` carga el clsuter y las iamgenes necesarias para cargar el pod del scheduler escogido 
y los pods de prueba para calcular las métricas sobre la ejecución de la logica del scheduler ante el despleigue de los pods de test.

No es necesario lanzas el script `scheduler-test.sh`, utilizando `Makefile` y pasandole el atributo que indique la peración que deseas realizar ya se puede comprobar cómo se carga y despliega el `scheduler personalizado` y los cambios de estado del pod añadido al clúster.

 
NOTA:

En este directorio se mantiene la versión de `my-scheduler` tipo `watch` con las funcionalidades del paso 8. Por ello deben mantenerse todos los manifiestos que contienen las modificaciones necesarias para su funciona,miento correcto. 
=======
Los ficheros que debe tenerse en este directoprio `py-scheduler` son:
 

- **Dockerfile**: Para crear la imagen en local `my-py-scheduler`
- **components.yaml**: Para el despliegue del servidor de métricas kubernetes
- **diagnose_fix.sh**: Script que carga el entorno y ejecuta los pods para ver los cambios de estado de los mismos. Se comprueba el buen funcionamientos de `my-scheduler`
- **kind-config.yaml**: Para la creación del clúster
- **rbac-deploy.yaml**: despliegue del scheduler personalizado dentro del control plane
- **requirements.txt**: Librerias necesarias para que el scheduler.py funcione
- **scheduler-test.sh**: Script que ejecuta los pods en el clsuter y calcula certas metriocas a partir de procesar las trazas del scheduler personalizado y el uso del servidor de métricas
- **scheduler.py**: Código python del scheduler personaizado
- **Manifiestos de lso pods usadados para p`robar el scheduler**:
    * test-nginx-pod.yaml
    * test-pod.yaml
    * test-worker3-pod.yaml

Nota: El desarrollo de lso scripts y métricas suponen, actualemtne, que caa pod sólo tiene un contenedor. Por ejemplo, Si un pod tiene múltiples contenedores, 
se toma el último started_at con max(started_times). Esto está bien, pero conviene ser consciente de que no almacena todos los contenedores, solo el “más reciente”.
