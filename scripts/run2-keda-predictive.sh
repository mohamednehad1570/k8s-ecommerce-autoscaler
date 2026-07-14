#!/bin/bash
# =============================================================================
# run2-keda-predictive.sh — Phase 9 Run 2: KEDA + Holt-Winters predictive
#
# What this script does:
#   1. Removes HPA if present (clean state)
#   2. Unsuspends KEDA ScaledObject (enables predictive scaling)
#   3. Waits for KEDA to pre-scale frontend based on predicted_rps
#   4. Starts same Locust profile as Run 1 (200 users, 10 min)
#   5. Pauses — you capture Grafana screenshots
#   6. On Enter: stops Locust, re-suspends KEDA, restores resting state
#
# Usage: bash scripts/run2-keda-predictive.sh
# Run AFTER run1-hpa-baseline.sh and after capturing Run 1 screenshots
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"
}

# ── Configuration — identical to Run 1 for fair comparison ───────────────────
NAMESPACE="online-boutique"
FRONTEND_DEPLOYMENT="frontend"
SCALEDOBJECT_NAME="frontend-scaledobject"
PEAK_USERS=200
SPAWN_RATE=3
RAMP_DURATION=180       # 3 min ramp
HOLD_DURATION=420       # 7 min hold
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       PHASE 9 — RUN 2: KEDA PREDICTIVE SCALING              ║${NC}"
echo -e "${BLUE}║       Peak users: ${PEAK_USERS} | Duration: ${TOTAL_DURATION}s (10 min)          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── STEP 1: Remove HPA if present ────────────────────────────────────────────
log "Step 1/6 — Removing HPA if present..."
kubectl delete hpa frontend-hpa-baseline -n ${NAMESPACE} --ignore-not-found
log "HPA absent ✅"

# ── STEP 2: Unsuspend KEDA ScaledObject ──────────────────────────────────────
log "Step 2/6 — Unsuspending KEDA ScaledObject (enabling predictive scaling)..."
kubectl patch scaledobject ${SCALEDOBJECT_NAME} \
  -n ${NAMESPACE} \
  --type merge \
  -p '{"spec":{"paused":false}}'
log "KEDA ScaledObject active ✅"

# ── STEP 3: Wait for KEDA to pre-scale based on predicted_rps ────────────────
log "Step 3/6 — Waiting 60s for KEDA to evaluate predicted_rps and pre-scale..."
warn "  Watch Grafana: frontend replicas should increase BEFORE load starts"
warn "  This pre-scaling is the thesis proof — pods ready before traffic lands"

# Poll replica count every 10 seconds for 60 seconds
for i in $(seq 1 6); do
  sleep 10
  REPLICAS=$(kubectl get deployment ${FRONTEND_DEPLOYMENT} \
    -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}')
  log "  [${i}0s] Frontend ready replicas: ${REPLICAS}"
done

PRE_SCALE_REPLICAS=$(kubectl get deployment ${FRONTEND_DEPLOYMENT} \
  -n ${NAMESPACE} \
  -o jsonpath='{.status.readyReplicas}')
log "Pre-load frontend replicas: ${PRE_SCALE_REPLICAS} ✅"
echo ""
warn "  ★ KEY METRIC: frontend has ${PRE_SCALE_REPLICAS} replica(s) BEFORE any load arrives"
warn "    Run 1 started with 1 replica — this difference is your thesis evidence"
echo ""

# ── STEP 4: Start Locust ──────────────────────────────────────────────────────
log "Step 4/6 — Starting Locust load test (identical profile to Run 1)..."
echo ""
warn "▶▶▶ GRAFANA: Note the start time for side-by-side comparison with Run 1"
warn "    Grafana URL: http://$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo ""

LOCUST_POD=$(kubectl get pod -n ${NAMESPACE} -l app=locust -o jsonpath='{.items[0].metadata.name}')

START_TIME=$(date '+%H:%M:%S')
log "Locust starting at ${START_TIME}"

kubectl exec -n ${NAMESPACE} ${LOCUST_POD} -- \
  locust \
  -f /locust/locustfile.py \
  --host http://frontend:80 \
  --headless \
  --users ${PEAK_USERS} \
  --spawn-rate ${SPAWN_RATE} \
  --run-time ${TOTAL_DURATION}s \
  --only-summary \
  --csv /tmp/run2 &

LOCUST_PID=$!

# ── STEP 5: Progress countdown ────────────────────────────────────────────────
log "Step 5/6 — Load test running..."
echo ""
echo -e "  ${YELLOW}RAMP PHASE${NC} (0 → ${PEAK_USERS} users over ${RAMP_DURATION}s):"
for i in $(seq 30 30 ${RAMP_DURATION}); do
  sleep 30
  elapsed=$i
  remaining=$((RAMP_DURATION - elapsed))
  if [ ${remaining} -gt 0 ]; then
    echo -e "  [$(date '+%H:%M:%S')] Ramping... ${elapsed}s elapsed, ${remaining}s until peak"
  fi
done

echo ""
echo -e "  ${YELLOW}HOLD PHASE${NC} (${PEAK_USERS} users for ${HOLD_DURATION}s):"
warn "  ★ PEAK LOAD — compare error rate and latency vs Run 1 in Grafana"
echo ""

for i in $(seq 60 60 ${HOLD_DURATION}); do
  sleep 60
  elapsed=$i
  remaining=$((HOLD_DURATION - elapsed))
  if [ ${remaining} -gt 0 ]; then
    echo -e "  [$(date '+%H:%M:%S')] Holding at peak... ${elapsed}s elapsed, ${remaining}s remaining"
  fi
done

wait ${LOCUST_PID} 2>/dev/null || true

STOP_TIME=$(date '+%H:%M:%S')
echo ""
log "Load test complete ✅"
log "  Started:  ${START_TIME}"
log "  Stopped:  ${STOP_TIME}"
echo ""

# ── STEP 6: Grafana capture pause ────────────────────────────────────────────
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  ★ CAPTURE GRAFANA SCREENSHOTS NOW ★                        ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  Set Grafana time range: ${START_TIME} → ${STOP_TIME}          ║${NC}"
echo -e "${RED}║  Panels to screenshot:                                       ║${NC}"
echo -e "${RED}║    1. Frontend replica count (pre-scaled BEFORE load)        ║${NC}"
echo -e "${RED}║    2. HTTP request rate (same load shape as Run 1)           ║${NC}"
echo -e "${RED}║    3. Frontend CPU usage (lower peak — more pods absorbing)  ║${NC}"
echo -e "${RED}║    4. predicted_rps (shows active predictive signal)         ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  KEY COMPARISON vs Run 1:                                    ║${NC}"
echo -e "${RED}║    • Replicas already > 1 when load started                  ║${NC}"
echo -e "${RED}║    • Smaller or zero error spike at ramp-up                  ║${NC}"
echo -e "${RED}║    • Lower p99 latency during ramp                           ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Press Enter when screenshots are saved to proceed with cleanup..."

# ── CLEANUP ───────────────────────────────────────────────────────────────────
log "Cleaning up Run 2..."

# Re-suspend KEDA — back to resting state
kubectl patch scaledobject ${SCALEDOBJECT_NAME} \
  -n ${NAMESPACE} \
  --type merge \
  -p '{"spec":{"paused":true}}'
log "KEDA re-suspended (resting state) ✅"

# Scale frontend back to 1
kubectl scale deployment ${FRONTEND_DEPLOYMENT} -n ${NAMESPACE} --replicas=1
log "Frontend scaled back to 1 ✅"

echo ""
log "Run 2 complete. Resting state restored."
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Both runs complete. Next steps:                             ║${NC}"
echo -e "${BLUE}║    1. Verify screenshots saved                               ║${NC}"
echo -e "${BLUE}║    2. Run gke-stop to stop billing                           ║${NC}"
echo -e "${BLUE}║    3. Start report writing with real data                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
