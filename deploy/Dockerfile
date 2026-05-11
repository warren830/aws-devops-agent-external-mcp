FROM public.ecr.aws/docker/library/python:3.12-slim

# Pin versions — do NOT use @latest in production. Bump via PR.
ARG AWS_MCP_VERSION=1.3.33

RUN pip install --no-cache-dir \
      "awslabs.aws-api-mcp-server==${AWS_MCP_VERSION}"

RUN useradd --create-home --shell /bin/bash app
USER app
WORKDIR /home/app

EXPOSE 8000
