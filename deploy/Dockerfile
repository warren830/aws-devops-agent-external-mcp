FROM public.ecr.aws/docker/library/python:3.12-slim

# Pin versions — bump via PR when upgrading.
# aws-api-mcp-server: 1.3.33, kubectl: v1.31.0 (matches bjs-web EKS cluster)
RUN pip install --no-cache-dir awslabs.aws-api-mcp-server==1.3.33

RUN python3 -c "\
import urllib.request, os; \
url='https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl'; \
urllib.request.urlretrieve(url, '/usr/local/bin/kubectl'); \
os.chmod('/usr/local/bin/kubectl', 0o755)"

COPY src/entrypoint.py /app/entrypoint.py

RUN useradd --create-home --shell /bin/bash app
USER app
WORKDIR /home/app

EXPOSE 8000

CMD ["python", "/app/entrypoint.py"]
