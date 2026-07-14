# FastAPI + Prophet prediction service
# Key design decision: CmdStan is installed to /opt/cmdstan (world-readable)
# and CMDSTAN env var is set so Prophet finds it regardless of which user runs it.
# This fixes the 'stan_backend' AttributeError caused by CmdStan being installed
# to ~/.cmdstan (root's home) but the app running as a non-root user at runtime.

FROM python:3.11-slim

# Build tools required by Prophet's Stan backend compilation
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        wget \
        curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies first — layer cache: unchanged = skipped on rebuild
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install CmdStan to a FIXED, world-readable path /opt/cmdstan.
# Default behaviour installs to ~/.cmdstan (root-only), which breaks
# when the container runs as a non-root user (appuser).
# Setting CMDSTAN env var here makes it permanent for all subsequent RUN steps
# and for the runtime container.
ENV CMDSTAN=/opt/cmdstan
RUN python -c "import cmdstanpy; cmdstanpy.install_cmdstan(dir='/opt/cmdstan')" && \
    chmod -R 755 /opt/cmdstan

# Copy training script and train the model AT BUILD TIME.
# Model is serialized to disk and baked into the image.
COPY train.py .
RUN python train.py

# Copy FastAPI application
COPY main.py .

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Non-root user — AFTER CmdStan is installed to /opt (world-readable)
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
