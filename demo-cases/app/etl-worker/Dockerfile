FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app
RUN pip install --no-cache-dir boto3==1.34.162

COPY worker.py /app/worker.py

ENV PYTHONUNBUFFERED=1
USER 10001
CMD ["python", "/app/worker.py"]
