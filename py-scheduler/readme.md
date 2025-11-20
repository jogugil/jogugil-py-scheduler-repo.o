Directorio de ejecución de los scripts con la copia del `scheduler.py` que se desee.
El script `scheduler-test.sh` carga el clsuter y las iamgenes necesarias para cargar el pod del scheduler escogido 
y los pods de prueba para calcular las métricas sobre la ejecución de la logica del scheduler ante el despleigue de los pods de test.

No es necesario lanzas el script `scheduler-test.sh`, utilizando `Makefile` y pasandole el atributo que indique la peración que deseas realizar ya se puede comprobar cómo se carga y despliega el `scheduler personalizado` y los cambios de estado del pod añadido al clúster.

NOTA:

En este directorio se mantiene la versión de `my-scheduler` tipo `watch` con las funcionalidades del paso 8. Por ello deben mantenerse todos los manifiestos que contienen las modificaciones necesarias para su funciona,miento correcto. 

