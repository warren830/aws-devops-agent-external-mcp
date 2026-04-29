FROM node:20-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 pipx curl \
    && pipx ensurepath && pipx install uv \
    && npm install -g supergateway \
    && rm -rf /var/lib/apt/lists/*
ENV PATH="/root/.local/bin:${PATH}"
ENV MCP_CMD=""
EXPOSE 8000
CMD supergateway --stdio "$MCP_CMD" --port 8000 --ssePath /sse --healthEndpoint /healthz
