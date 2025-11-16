FROM python:3.11-slim
RUN pip install numpy
CMD ["python3", "-c", "import numpy as np; [np.random.rand(1000000)**2 for _ in range(1000)]; import time; time.sleep(3600)"]
