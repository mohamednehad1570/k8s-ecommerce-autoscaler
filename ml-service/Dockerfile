
# Multi-stage build for the FastAPI + Prophet prediction service.
# Stage 1 (builder): installs all Python dependencies including Prophet + Stan compiler
# Stage 2 (runtime): copies only the installed packages + trained model — no build tools
# Result: smaller final image + smaller Trivy attack surface

# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

# Prophet requires gcc/g++ to compile its Stan backend during pip install
# build-essential: provides gcc, g++, make
# pkg-config: locates C libraries during compilation
# rm -rf /var/lib/apt/lists/*: delete apt cache to keep this layer small
RUN apt-get update && \
    apt-get install -y build-essential pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements first — Docker layer cache: if unchanged, pip install is skipped
COPY requirements.txt .

# Install all dependencies into /app/deps (not system Python)
# --target /app/deps: isolated directory, easy to copy into runtime stage
# --no-cache-dir: don't store pip download cache in the image layer
RUN pip install --no-cache-dir pip==24.0 && \
    pip install --no-cache-dir -r requirements.txt --target /app/deps

# Copy and run the training script AT BUILD TIME
# This bakes the trained Prophet model into the image — zero cold-start delay at runtime
COPY train.py .
RUN PYTHONPATH=/app/deps python train.py

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

WORKDIR /app

# Non-root user: security best practice — limits blast radius if container is compromised
# Falco (our runtime security tool) alerts on root-running containers
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Copy installed Python packages from builder stage
COPY --from=builder /app/deps /app/deps

# Copy the trained model from builder stage — baked in, ready at pod startup
COPY --from=builder /app/model ./model

# Copy the FastAPI application
COPY main.py .

# PYTHONPATH: tells Python where to find the packages we copied from builder
ENV PYTHONPATH=/app/deps

# PYTHONDONTWRITEBYTECODE: skip .pyc files — no benefit in containers
ENV PYTHONDONTWRITEBYTECODE=1

# PYTHONUNBUFFERED: stdout/stderr appear immediately — critical for live logs
ENV PYTHONUNBUFFERED=1

# Switch to non-root user for runtime
USER appuser

EXPOSE 8000

# HEALTHCHECK: Docker-level probe (Kubernetes uses its own probes from the manifest)
# /health: matches the endpoint defined in main.py
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Start uvicorn with 1 worker — Prophet is memory-heavy; 2 workers doubles RAM usage
# for no throughput gain on a single-prediction-at-a-time workload
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
