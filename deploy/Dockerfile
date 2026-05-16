FROM public.ecr.aws/docker/library/python:3.12-slim

# Pin versions — do NOT use @latest in production. Bump via PR.
ARG AWS_MCP_VERSION=1.3.33
ARG KUBECTL_VERSION=v1.31.0

RUN pip install --no-cache-dir \
      "awslabs.aws-api-mcp-server==${AWS_MCP_VERSION}"

# kubectl binary — same version as the EKS cluster (bjs-web is 1.31)
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    apt-get remove -y curl && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

COPY src/entrypoint.py /app/entrypoint.py

RUN useradd --create-home --shell /bin/bash app
USER app
WORKDIR /home/app

EXPOSE 8000

CMD ["python", "/app/entrypoint.py"]
