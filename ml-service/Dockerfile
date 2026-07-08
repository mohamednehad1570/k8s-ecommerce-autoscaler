# Multi-stage build for the FastAPI prediction service.
#
# Stage 1 (builder): installs Python dependencies into an isolated layer
# Stage 2 (runtime): copies only what's needed — no build tools in final image
#
# Multi-stage = smaller final image + smaller attack surface for Trivy scans
# =============================================================================

# --- Stage 1: builder ---
# python:3.11-slim: official Python image on Debian slim (smaller than full Debian)
# 3.11 specifically: Prophet and its scipy/numpy dependencies are well-tested on 3.11
FROM python:3.11-slim AS builder

# WORKDIR: sets the working directory for all subsequent instructions in this stage
# /app: conventional path for application code inside a container
WORKDIR /app

# Copy only the requirements file first — before copying any source code.
# Docker builds in layers. If requirements.txt hasn't changed, Docker reuses
# the cached pip install layer — much faster rebuilds during development.
COPY requirements.txt .

# Install dependencies into a local directory instead of system Python.
# - `--no-cache-dir`: don't cache downloaded packages — keeps image smaller
# - `--upgrade pip`: ensures pip itself is current before installing anything
# - `-r requirements.txt`: install everything listed in the requirements file
# - `--target /app/deps`: install packages into /app/deps instead of system site-packages
#   This makes it easy to copy just the deps into the runtime stage
RUN pip install --no-cache-dir pip==24.0 \
    && pip install --no-cache-dir -r requirements.txt --target /app/deps

# --- Stage 2: runtime ---
# Fresh base image — no pip, no build tools, no cache from Stage 1
# Only the application code and its installed dependencies are copied in
FROM python:3.11-slim AS runtime

# Set working directory in the final image
WORKDIR /app

# Create a non-root user and group to run the application.
# Running as root inside a container is a security risk —
# if the container is compromised, the attacker has root on the container filesystem.
# Falco (our runtime security tool) will alert on root-running containers.
# - `addgroup`: creates a group named 'appgroup'
# - `adduser`: creates user 'appuser', assigned to 'appgroup', no password, no home dir
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Copy installed Python packages from the builder stage.
# - `--from=builder`: pulls files from the Stage 1 filesystem, not the host
# - `/app/deps`: the directory where pip installed packages in Stage 1
# - `/app/deps`: destination in the runtime image
COPY --from=builder /app/deps /app/deps

# Copy the application source code into the runtime image
COPY main.py .

# Tell Python where to find the installed packages we copied from builder.
# - PYTHONPATH: Python checks this directory path when importing modules
# - /app/deps: where our pip packages live (copied from builder above)
ENV PYTHONPATH=/app/deps

# Tell Python not to write .pyc bytecode cache files to disk.
# In containers, bytecode caching wastes space and causes confusing behaviour.
ENV PYTHONDONTWRITEBYTECODE=1

# Tell Python not to buffer stdout/stderr.
# Buffering means log lines may not appear immediately — dangerous in production
# because you'd miss logs during a crash. Unbuffered = logs appear instantly.
ENV PYTHONUNBUFFERED=1

# Switch to the non-root user for all subsequent instructions and at runtime
USER appuser

# Document that the container listens on port 8000.
# EXPOSE does NOT publish the port — it's documentation for tooling and humans.
# The actual port binding happens in the Kubernetes Service manifest (Phase 5).
EXPOSE 8000

# Health check: Docker (and some orchestrators) will call this periodically.
# - `--interval=30s`: check every 30 seconds
# - `--timeout=5s`: fail if no response within 5 seconds
# - `--start-period=10s`: give the app 10 seconds to start before first check
# - `--retries=3`: mark unhealthy only after 3 consecutive failures
# curl -f: exits with error code if HTTP response is not 2xx — triggers health check failure
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/healthz || exit 1

# CMD: the default command that runs when the container starts.
# Uses exec form (JSON array) — avoids spawning a shell wrapper process.
# - `uvicorn`: ASGI server that serves the FastAPI application
# - `main:app`: module name `main` (main.py), FastAPI instance named `app`
# - `--host 0.0.0.0`: listen on all network interfaces (not just localhost)
#   Required inside a container — 127.0.0.1 would be unreachable from outside
# - `--port 8000`: the port uvicorn binds to (matches EXPOSE above)
# - `--workers 2`: two worker processes — handles concurrent requests
#   In Phase 8 with Prophet loaded: increase to 4 for inference throughput
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
