
"""
train.py — Offline model training script.
Executed once during Docker image build: RUN python train.py
Produces: model/prophet_model.joblib

Design: training at build time means zero cold-start delay at runtime.
The pod loads a ready model instantly on startup.
"""

import pandas as pd
import numpy as np
from prophet import Prophet
import joblib
import os
from datetime import datetime, timedelta

print("Generating synthetic traffic dataset...")

# ── Generate 8 weeks of hourly synthetic RPS data ────────────────────────────
start_date = datetime(2024, 9, 27)          # arbitrary historical start
periods = 8 * 7 * 24                        # 8 weeks × 7 days × 24 hours = 1344 points

# Generate one timestamp per hour
timestamps = [start_date + timedelta(hours=i) for i in range(periods)]

# Component 1 — Daily seasonality: smooth sine curve peaking at business hours
# np.sin maps hour-of-day to a 0→1→0 curve; max(0,...) clips the nighttime trough
daily = np.array([
    0.3 + 0.7 * max(0, np.sin(np.pi * (t.hour - 6) / 14))
    for t in timestamps
])

# Component 2 — Weekly seasonality: weekdays 30% busier than weekends
weekly = np.array([
    1.3 if t.weekday() < 5 else 0.7        # Mon-Fri = 1.3, Sat-Sun = 0.7
    for t in timestamps
])

# Component 3 — Black Friday spike: 4× surge on week 7 Friday
# Gaussian curve: sharp peak at Black Friday, decays within ±2 days
black_friday = start_date + timedelta(weeks=6, days=4)
spike = np.array([
    4.0 * np.exp(-((t - black_friday).total_seconds() / 3600) ** 2 / (2 * 12 ** 2))
    for t in timestamps
])

# Combine all components into final RPS signal
# Base 50 RPS × daily shape × weekly shape + Black Friday spike + noise
np.random.seed(42)                          # seed: reproducible noise across builds
rps = 50 * daily * weekly + spike * 50 + np.random.normal(0, 5, periods)
rps = np.clip(rps, 0, None)                # clip: RPS never negative

# Prophet requires exactly two columns: 'ds' (datestamp) and 'y' (value)
df = pd.DataFrame({'ds': timestamps, 'y': rps})
print(f"Dataset: {len(df)} points | RPS range: {df['y'].min():.1f} – {df['y'].max():.1f}")

# ── Train Prophet model ───────────────────────────────────────────────────────
print("Training Prophet model...")
model = Prophet(
    daily_seasonality=True,                 # learn hour-of-day traffic patterns
    weekly_seasonality=True,                # learn day-of-week traffic patterns
    yearly_seasonality=False,               # off — only 8 weeks of data, no yearly signal
    changepoint_prior_scale=0.1,            # trend flexibility: 0.1 = moderate (default 0.05 too rigid for spikes)
    interval_width=0.95                     # 95% confidence interval on all forecasts
)
model.fit(df)
print("Training complete.")

# ── Serialize model to disk ───────────────────────────────────────────────────
os.makedirs("model", exist_ok=True)         # create model/ directory if it doesn't exist
joblib.dump(model, "model/prophet_model.joblib")  # serialize trained model to binary file
print("Model saved → model/prophet_model.joblib")
