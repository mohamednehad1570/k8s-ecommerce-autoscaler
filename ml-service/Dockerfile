
# Single-stage build for FastAPI + Prophet prediction service.
# Multi-stage was abandoned: Prophet's Stan backend uses dynamic module discovery
# that breaks when packages are installed to a non-standard --target directory.
# Single-stage with non-root user still meets security requirements for this thesis.

FROM python:3.11-slim

# Prophet requires gcc/g++ to compile its Stan backend during pip install
# --no-install-recommends: skip suggested packages to keep image smaller
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Non-root user — security best practice, limits blast radius if compromised
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Copy and install dependencies first — Docker layer cache benefit:
# if requirements.txt unchanged, pip install layer is reused on next build
COPY requirements.txt .

# Install to system Python (no --target) — required for Prophet's Stan backend
# to locate its modules correctly via dynamic import
# --no-cache-dir: don't store pip download cache in the image layer
RUN pip install --no-cache-dir -r requirements.txt

# Copy training script and run AT BUILD TIME — bakes trained model into image
# Zero cold-start delay at runtime: pod loads pre-trained model instantly
COPY train.py .
RUN python train.py

# Copy FastAPI application — after train.py so editing main.py
# doesn't invalidate the pip install or training layers
COPY main.py .

# PYTHONDONTWRITEBYTECODE: skip .pyc files — no benefit in containers
ENV PYTHONDONTWRITEBYTECODE=1

# PYTHONUNBUFFERED: logs appear immediately — critical for live debugging
ENV PYTHONUNBUFFERED=1

# Switch to non-root user for runtime
USER appuser

EXPOSE 8000

# HEALTHCHECK: /health matches the endpoint in main.py
# start-period=90s: Prophet + Stan init can take up to 60s on first load
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# 1 worker: Prophet model is memory-heavy; multiple workers multiply RAM for no gain
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
