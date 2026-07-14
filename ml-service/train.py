import numpy as np
import pandas as pd
from statsmodels.tsa.holtwinters import ExponentialSmoothing
import joblib
import os
from datetime import datetime, timedelta

print("Generating synthetic traffic dataset...")
start_date = datetime(2024, 9, 27)
periods = 8 * 7 * 24

timestamps = [start_date + timedelta(hours=i) for i in range(periods)]

daily = np.array([0.3 + 0.7 * max(0, np.sin(np.pi * (t.hour - 6) / 14)) for t in timestamps])
weekly = np.array([1.3 if t.weekday() < 5 else 0.7 for t in timestamps])

black_friday = start_date + timedelta(weeks=6, days=4)
spike = np.array([
    4.0 * np.exp(-((t - black_friday).total_seconds() / 3600) ** 2 / (2 * 12 ** 2))
    for t in timestamps
])

np.random.seed(42)
rps = 50 * daily * weekly + spike * 50 + np.random.normal(0, 5, periods)
rps = np.clip(rps, 0, None)

series = pd.Series(rps, index=pd.date_range(start=start_date, periods=periods, freq='h'))
print(f"Dataset: {len(series)} points | RPS range: {series.min():.1f} - {series.max():.1f}")

print("Training Holt-Winters model...")
model = ExponentialSmoothing(series, trend='add', seasonal='add', seasonal_periods=24)
fitted_model = model.fit(optimized=True)
print("Training complete.")

os.makedirs("model", exist_ok=True)
joblib.dump(fitted_model, "model/hw_model.joblib")
print("Model saved to model/hw_model.joblib")
