#!/bin/bash
# =============================================================================
# run1-hpa-baseline.sh — Phase 9 Run 1: Reactive HPA baseline
#
# What this script does:
#   1. Suspends KEDA ScaledObject (disables predictive scaling)
#   2. Scales frontend to exactly 1 replica (clean starting state)
#   3. Applies a plain HPA (CPU threshold 50%) — reactive only
#   4. Starts Locust: ramps to 200 users over 3 min, holds 7 min
#   5. Pauses — you capture Grafana screenshots
#   6. On Enter: stops Locust, removes HPA, restores resting state
#
# Usage: bash scripts/run1-hpa-baseline.sh
# Prerequisites: cluster up, all pods Running, Grafana open in browser
# =============================================================================

set -e  # exit immediately if any command fails

# ── Colours for readable output ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colour

# ── Helper: print timestamped log line ───────────────────────────────────────
log() {
  echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"
}

# ── Configuration — edit here if you want different parameters ────────────────
NAMESPACE="online-boutique"
FRONTEND_DEPLOYMENT="frontend"
SCALEDOBJECT_NAME="frontend-scaledobject"
LOCUST_DEPLOYMENT="locust"
PEAK_USERS=200          # peak concurrent users
SPAWN_RATE=3            # users added per second during ramp
RAMP_DURATION=180       # 3 minutes ramp (seconds)
HOLD_DURATION=420       # 7 minutes hold at peak (seconds)
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))  # 10 min total

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════
# Write Run 1 script — HPA reactive baseline
cat > ~/k8s-ecommerce-autoscaler/scripts/run1-hpa-baseline.sh << 'SCRIPT_EOF'
#!/bin/bash
# =============================================================================
# run1-hpa-baseline.sh — Phase 9 Run 1: Reactive HPA baseline
#
# What this script does:
#   1. Suspends KEDA ScaledObject (disables predictive scaling)
#   2. Scales frontend to exactly 1 replica (clean starting state)
#   3. Applies a plain HPA (CPU threshold 50%) — reactive only
#   4. Starts Locust: ramps to 200 users over 3 min, holds 7 min
#   5. Pauses — you capture Grafana screenshots
#   6. On Enter: stops Locust, removes HPA, restores resting state
#
# Usage: bash scripts/run1-hpa-baseline.sh
# Prerequisites: cluster up, all pods Running, Grafana open in browser
# =============================================================================

set -e  # exit immediately if any command fails

# ── Colours for readable output ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colour

# ── Helper: print timestamped log line ───────────────────────────────────────
log() {
  echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"
}

# ── Configuration — edit here if you want different parameters ────────────────
NAMESPACE="online-boutique"
FRONTEND_DEPLOYMENT="frontend"
SCALEDOBJECT_NAME="frontend-scaledobject"
LOCUST_DEPLOYMENT="locust"
PEAK_USERS=200          # peak concurrent users
SPAWN_RATE=3            # users added per second during ramp
RAMP_DURATION=180       # 3 minutes ramp (seconds)
HOLD_DURATION=420       # 7 minutes hold at peak (seconds)
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))  # 10 min total

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         PHASE 9 — RUN 1: HPA REACTIVE BASELINE              ║${NC}"
echo -e "${BLUE}║         Peak users: ${PEAK_USERS} | Duration: ${TOTAL_DURATION}s (10 min)          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── STEP 1: Suspend KEDA ScaledObject ────────────────────────────────────────
log "Step 1/6 — Suspending KEDA ScaledObject (disabling predictive scaling)..."
kubectl patch scaledobject ${SCALEDOBJECT_NAME} \
  -n ${NAMESPACE} \
  --type merge \
  -p '{"spec":{"paused":true}}'
sleep 5  # give KEDA time to release HPA ownership

# ── STEP 2: Scale frontend to 1 replica ──────────────────────────────────────
log "Step 2/6 — Scaling frontend to 1 replica (clean baseline state)..."
kubectl scale deployment ${FRONTEND_DEPLOYMENT} \
  -n ${NAMESPACE} \
  --replicas=1
# Wait until exactly 1 pod is ready
kubectl rollout status deployment/${FRONTEND_DEPLOYMENT} -n ${NAMESPACE} --timeout=120s
log "Frontend at 1 replica ✅"

# ── STEP 3: Apply HPA ─────────────────────────────────────────────────────────
log "Step 3/6 — Applying HPA (CPU 50% threshold, 1-5 replicas)..."
kubectl apply -f kubernetes/locust/frontend-hpa.yaml
sleep 10  # give HPA time to register
log "HPA active ✅"

# ── STEP 4: Start Locust ──────────────────────────────────────────────────────
log "Step 4/6 — Starting Locust load test..."
echo ""
warn "▶▶▶ GRAFANA: Open your dashboard NOW and note the start time"
warn "    Grafana URL: http://$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo ""

# Get Locust pod name
LOCUST_POD=$(kubectl get pod -n ${NAMESPACE} -l app=locust -o jsonpath='{.items[0].metadata.name}')

START_TIME=$(date '+%H:%M:%S')
log "Locust starting at ${START_TIME} — target: ${PEAK_USERS} users, spawn rate: ${SPAWN_RATE}/sec"

# Start Locust inside the pod — runs for TOTAL_DURATION seconds then auto-stops
kubectl exec -n ${NAMESPACE} ${LOCUST_POD} -- \
  locust \
  -f /locust/locustfile.py \
  --host http://frontend:80 \
  --headless \
  --users ${PEAK_USERS} \
  --spawn-rate ${SPAWN_RATE} \
  --run-time ${TOTAL_DURATION}s \
  --only-summary \
  --csv /tmp/run1 &   # & = runs in background so script can print progress

LOCUST_PID=$!  # capture background process ID

# ── STEP 5: Progress countdown ────────────────────────────────────────────────
log "Step 5/6 — Load test running..."
echo ""
echo -e "  ${YELLOW}RAMP PHASE${NC} (0 → ${PEAK_USERS} users over ${RAMP_DURATION}s):"
# Print countdown every 30 seconds during ramp
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
warn "  ★ PEAK LOAD REACHED — watch Grafana for HPA scaling events"
echo ""

# Print countdown every 60 seconds during hold
for i in $(seq 60 60 ${HOLD_DURATION}); do
  sleep 60
  elapsed=$i
  remaining=$((HOLD_DURATION - elapsed))
  if [ ${remaining} -gt 0 ]; then
    echo -e "  [$(date '+%H:%M:%S')] Holding at peak... ${elapsed}s elapsed, ${remaining}s remaining"
  fi
done

# Wait for Locust background process to finish
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
echo -e "${RED}║    1. Frontend replica count (shows HPA scaling delay)       ║${NC}"
echo -e "${RED}║    2. HTTP request rate (shows load shape)                   ║${NC}"
echo -e "${RED}║    3. Frontend CPU usage (shows reactive trigger)            ║${NC}"
echo -e "${RED}║    4. predicted_rps (should be flat — KEDA suspended)        ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Press Enter when screenshots are saved to proceed with cleanup..."

# ── CLEANUP ───────────────────────────────────────────────────────────────────
log "Cleaning up Run 1..."

# Remove HPA
kubectl delete hpa frontend-hpa-baseline -n ${NAMESPACE} --ignore-not-found
log "HPA removed ✅"

# Scale frontend back to 1
kubectl scale deployment ${FRONTEND_DEPLOYMENT} -n ${NAMESPACE} --replicas=1
log "Frontend scaled back to 1 ✅"

# Keep KEDA suspended — resting state between runs
warn "KEDA remains suspended (resting state). Run run2-keda-predictive.sh to activate predictive scaling."

echo ""
log "Run 1 complete. Resting state restored."
echo -e "${BLUE}Next step: bash scripts/run2-keda-predictive.sh${NC}"
echo ""
