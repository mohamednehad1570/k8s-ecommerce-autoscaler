
"""
main.py — FastAPI prediction service (runtime).
Loads the pre-trained Prophet model baked into the image by train.py at build time.
Serves:
  GET /health   — liveness + readiness probe (Kubernetes)
  GET /predict  — returns predicted RPS for the next N minutes
  GET /metrics  — Prometheus text format; exposes predicted_rps Gauge for KEDA
"""

import joblib                               # joblib: deserialize Prophet model from disk
import pandas as pd                         # pandas: required by Prophet for DataFrames
from fastapi import FastAPI                 # FastAPI: web framework
from prometheus_client import (
    Gauge,                                  # Gauge: metric type whose value can go up or down
    generate_latest,                        # generate_latest: renders all metrics as Prometheus text
    CONTENT_TYPE_LATEST                     # CONTENT_TYPE_LATEST: correct HTTP Content-Type header
)
from starlette.responses import Response    # Response: returns raw text with custom Content-Type
from datetime import datetime, timedelta    # datetime: builds Prophet's future timestamp DataFrame
import os                                   # os: reads MODEL_PATH environment variable

# ── App initialisation ────────────────────────────────────────────────────────
app = FastAPI(
    title="ML Prediction Service",
    description="Prophet-based traffic forecasting for KEDA predictive autoscaling",
    version="1.0.0",
)

# ── Load pre-trained model at startup ─────────────────────────────────────────
# Runs once when the pod starts — not on every request.
# The model file was baked into the Docker image by train.py during docker build.
# os.getenv: reads the env var; falls back to the default path if not set
MODEL_PATH = os.getenv("MODEL_PATH", "model/prophet_model.joblib")
print(f"Loading Prophet model from {MODEL_PATH}...")
model = joblib.load(MODEL_PATH)             # deserialize the binary model file into memory
print("Model loaded successfully.")

# ── Prometheus Gauge ──────────────────────────────────────────────────────────
# 'predicted_rps': the metric name Prometheus scrapes and KEDA queries
# This single Gauge is the bridge between Prophet and KEDA
predicted_rps_gauge = Gauge(
    'predicted_rps',
    'Predicted requests per second for the next forecast window (Prophet)'
)

# ── /health — liveness + readiness probe ─────────────────────────────────────
# Kubernetes calls this on a schedule via livenessProbe and readinessProbe.
# Returns 200 as long as the pod is alive and the model is loaded.
@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": model is not None}

# ── /predict — core forecasting endpoint ─────────────────────────────────────
# Query param `minutes`: how far ahead to forecast (default: 30 minutes)
# Returns mean predicted RPS across that window and updates the Prometheus Gauge.
@app.get("/predict")
def predict(minutes: int = 30):
    # Build future DataFrame: Prophet requires a 'ds' column of future timestamps
    now = datetime.utcnow()
    # pd.date_range: generates evenly-spaced timestamps
    # freq="1min": one point per minute
    # periods=minutes: total number of future points
    future_df = pd.DataFrame({
        'ds': pd.date_range(start=now, periods=minutes, freq="1min")
    })

    # model.predict(): runs the trained model on future timestamps
    # Returns DataFrame with: ds, yhat (mean forecast), yhat_lower, yhat_upper
    forecast = model.predict(future_df)

    # Extract mean predicted RPS across the forecast window
    # 'yhat': Prophet's column name for the point forecast
    mean_prediction = float(forecast['yhat'].mean())

    # Clamp to zero — Prophet can produce slightly negative values at low-traffic periods
    mean_prediction = max(0.0, mean_prediction)

    # Update the Gauge — KEDA reads this value via PromQL query on Prometheus
    predicted_rps_gauge.set(mean_prediction)

    return {
        "forecast_minutes": minutes,
        "predicted_rps": mean_prediction,
        "forecast_start": now.isoformat(),
        "forecast_end": (now + timedelta(minutes=minutes)).isoformat(),
    }

# ── /metrics — Prometheus scrape endpoint ────────────────────────────────────
# Prometheus (via ServiceMonitor) hits this every 15s.
# Returns all registered Gauges/Counters in Prometheus text exposition format.
@app.get("/metrics")
def metrics():
    return Response(
        content=generate_latest(),          # renders all metrics as UTF-8 text
        media_type=CONTENT_TYPE_LATEST      # "text/plain; version=0.0.4; charset=utf-8"
    )

# ── Startup: prime the Gauge before first Prometheus scrape ──────────────────
# Without this the Gauge is 0 on startup — KEDA would see no signal for ~15s.
@app.on_event("startup")
async def startup_event():
    print("Priming prediction gauge on startup...")
    predict(minutes=30)                     # warm-up forecast: 30 minutes ahead
    print("Initial predicted_rps gauge primed.")
