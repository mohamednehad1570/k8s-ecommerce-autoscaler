# ml-service/main.py
# Placeholder FastAPI service for the Prophet-based prediction engine.
# Phase 8 will replace the /predict stub with real Prophet forecasting logic.
# Production-shaped: health probes, structured schemas, proper HTTP status codes.
# =============================================================================

from fastapi import FastAPI, HTTPException  # FastAPI: web framework; HTTPException: structured error responses
from pydantic import BaseModel              # BaseModel: defines and validates request/response data shapes
from datetime import datetime               # datetime: generates UTC timestamps for responses
import os                                   # os: read environment variables for runtime config

# ---------------------------------------------------------------------------
# App initialisation
# ---------------------------------------------------------------------------
app = FastAPI(
    title="ML Prediction Service",          # title: appears in auto-generated /docs Swagger UI
    description="Prophet-based traffic forecasting for KEDA predictive autoscaling",
    version="0.1.0",                        # 0.x = pre-release; bump to 1.0.0 when Prophet is integrated
)

# ---------------------------------------------------------------------------
# Request / Response schemas
# Pydantic validates incoming JSON against these automatically.
# If a request doesn't match the schema, FastAPI returns 422 before your code runs.
# ---------------------------------------------------------------------------
class PredictRequest(BaseModel):
    horizon_minutes: int = 30              # how many minutes ahead to forecast; default 30

class PredictResponse(BaseModel):
    predicted_replicas: int                # pod replica count KEDA should scale to
    confidence: float                      # forecast confidence 0.0-1.0; 0.0 = stub placeholder
    forecast_timestamp: str                # ISO-8601 UTC timestamp of when forecast was generated
    horizon_minutes: int                   # echoed back so the caller can confirm what was requested

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

# /healthz — Kubernetes liveness probe
# kubelet calls this on a schedule; non-200 response triggers pod restart
@app.get("/healthz")
def healthz():
    return {"status": "ok"}

# /readyz — Kubernetes readiness probe
# kubelet calls this before sending traffic; non-200 keeps pod out of rotation
# In Phase 8: return 503 here if the Prophet model hasn't loaded yet
@app.get("/readyz")
def readyz():
    return {"status": "ready"}

# /predict — main KEDA integration endpoint
# KEDA external scaler POSTs here; response tells it how many replicas to provision
# Phase 8 replaces the stub values with real Prophet model inference
@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    # Validate input — horizon must be a positive integer
    if req.horizon_minutes <= 0:
        # HTTPException: FastAPI serialises this as structured JSON error response
        # status_code=422: Unprocessable Entity — semantically correct for invalid input
        raise HTTPException(
            status_code=422,
            detail="horizon_minutes must be a positive integer"
        )

    # --- STUB: replace entirely with Prophet inference in Phase 8 ---
    stub_replicas = 3                      # hardcoded placeholder — not a real forecast
    stub_confidence = 0.0                  # 0.0 explicitly signals this is a stub
    # --- end stub ---

    return PredictResponse(
        predicted_replicas=stub_replicas,
        confidence=stub_confidence,
        # datetime.utcnow(): current time in UTC (no timezone offset)
        # .isoformat(): formats as "2026-07-08T13:45:00.123456"
        # + "Z": appends UTC timezone marker (Z = Zulu = UTC in ISO-8601)
        forecast_timestamp=datetime.utcnow().isoformat() + "Z",
        horizon_minutes=req.horizon_minutes,
    )
