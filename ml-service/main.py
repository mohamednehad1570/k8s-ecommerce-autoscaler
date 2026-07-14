import joblib
import pandas as pd
from fastapi import FastAPI
from prometheus_client import Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response
from datetime import datetime, timedelta
import os

app = FastAPI(
    title="ML Prediction Service",
    description="Holt-Winters traffic forecasting for KEDA predictive autoscaling",
    version="1.0.0",
)

MODEL_PATH = os.getenv("MODEL_PATH", "model/hw_model.joblib")
print(f"Loading Holt-Winters model from {MODEL_PATH}...")
fitted_model = joblib.load(MODEL_PATH)
print("Model loaded successfully.")

predicted_rps_gauge = Gauge(
    'predicted_rps',
    'Predicted requests per second for next forecast window (Holt-Winters)'
)

@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": fitted_model is not None}

@app.get("/predict")
def predict(minutes: int = 30):
    forecast_values = fitted_model.forecast(steps=minutes)
    mean_prediction = max(0.0, float(forecast_values.mean()))
    predicted_rps_gauge.set(mean_prediction)
    now = datetime.utcnow()
    return {
        "forecast_minutes": minutes,
        "predicted_rps": mean_prediction,
        "forecast_start": now.isoformat(),
        "forecast_end": (now + timedelta(minutes=minutes)).isoformat(),
    }

@app.get("/metrics")
def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.on_event("startup")
async def startup_event():
    print("Priming prediction gauge on startup...")
    predict(minutes=30)
    print("Startup gauge primed.")
