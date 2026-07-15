#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# run2-keda-predictive.sh — Phase 9 Run 2: KEDA Predictive Scaling
#
# PURPOSE:
#   Demonstrates predictive autoscaling using KEDA driven by the Holt-Winters
#   ML forecast (predicted_rps). Services pre-scale BEFORE load arrives.
#   Identical Locust profile to Run 1 — the only difference is the autoscaler.
#
# PROFILE:
#   200 users | 3 users/sec spawn | 3 min ramp + 7 min hold = 10 min total
#
# WHAT TO WATCH IN GRAFANA (http://35.205.175.90):
#   Panel 1 — Replicas already at ceiling BEFORE Locust starts (pre-scaling)
#   Panel 2 — No gap between desired and ready (zero scaling lag)
#   Panel 3 — CPU flat per pod because load is distributed across pre-scaled pods
#   Panel 7 — predicted_rps driving KEDA threshold BEFORE load lands (thesis proof)
#
# KEY THESIS EVIDENCE:
#   Compare the timestamp on Panel 6 (spec replicas step-up) vs Locust start time.
#   In Run 1: step-up happens AFTER load. In Run 2: step-up happens BEFORE load.
#   That timing difference is the entire thesis.
# ─────────────────────────────────────────────────────────────────────────────
set -e

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m';  RED='\033[0;31m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"; }
info() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
fail() { echo -e "${RED}[$(date '+%H:%M:%S')] FATAL: $1${NC}"; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
NAMESPACE="online-boutique"
GRAFANA_IP="35.205.175.90"
DASHBOARD_UID="phase9-autoscaling"
SERVICES="frontend-scaledobject cartservice-scaledobject productcatalogservice-scaledobject"
DEPLOYMENTS="frontend cartservice productcatalogservice"
PEAK_USERS=200
SPAWN_RATE=3
RAMP_DURATION=180
HOLD_DURATION=420
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))
PRE_SCALE_WAIT=90        # seconds to wait for KEDA to pre-scale after unpause
PRE_SCALE_MIN_REPLICAS=5 # minimum replicas required before Locust is allowed to start

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     PHASE 9 — RUN 2: KEDA PREDICTIVE SCALING                ║${NC}"
echo -e "${BLUE}║     Peak: ${PEAK_USERS} users | Spawn: ${SPAWN_RATE}/sec | Duration: ${TOTAL_DURATION}s       ║${NC}"
echo -e "${BLUE}║     Grafana: http://${GRAFANA_IP}                      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── PRE-RUN STATE SNAPSHOT ────────────────────────────────────────────────────
info "PRE-RUN STATE SNAPSHOT:"
info "  Deployment replicas before run (should all be 1 after Run 1 cooldown):"
for d in ${DEPLOYMENTS}; do
  READY=$(kubectl get deployment ${d} -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl get deployment ${d} -n ${NAMESPACE} \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  info "    ${d}: ${READY}/${DESIRED} ready"
  # Warn if any service is not at 1 — means Run 1 cooldown did not complete
  [ "${DESIRED}" != "1" ] && \
    warn "    WARNING: ${d} desired=${DESIRED}, expected 1. Run 1 cooldown may be incomplete."
done

info "  ML predicted_rps (current — this is what KEDA will act on):"
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus \
  9191:9090 > /dev/null 2>&1 &
PF_PID=$!
sleep 2
PRED=$(curl -s 'http://localhost:9191/api/v1/query?query=predicted_rps' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
    print(d['data']['result'][0]['value'][1] if d['data']['result'] else 'N/A')" \
  2>/dev/null || echo "N/A")
kill ${PF_PID} 2>/dev/null || true
info "    predicted_rps = ${PRED} req/s"
info "    KEDA threshold per service = predicted_rps / 5 = $(python3 -c \
  "print(round(float('${PRED}')/5,2) if '${PRED}' != 'N/A' else 'N/A')" \
  2>/dev/null || echo 'N/A') → triggers scaling"

info "  KEDA ScaledObject states (should all be paused=true from Run 1):"
for so in ${SERVICES}; do
  STATE=$(kubectl get scaledobject ${so} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}' \
    2>/dev/null || echo "unknown")
  info "    ${so}: paused=${STATE}"
done
echo ""

# ── STEP 1 — Confirm no HPAs present ─────────────────────────────────────────
log "Step 1/6 — Confirming HPAs are absent (Run 1 cleanup gate)..."
kubectl delete hpa \
  frontend-hpa-baseline \
  cartservice-hpa-baseline \
  productcatalogservice-hpa-baseline \
  -n ${NAMESPACE} --ignore-not-found
sleep 5
log "  HPAs absent OK"

# ── STEP 2 — Unsuspend KEDA (annotation-based, hard-verified) ────────────────
log "Step 2/6 — Unsuspending all 3 KEDA ScaledObjects..."
for so in ${SERVICES}; do
  # Setting paused=false re-activates the ScaledObject — KEDA operator
  # will immediately begin evaluating triggers and adjusting replica counts
  kubectl annotate scaledobject ${so} -n ${NAMESPACE} \
    autoscaling.keda.sh/paused="false" --overwrite
done
sleep 15

# Hard verification — refuse to proceed unless every ScaledObject is active
log "  Verifying unpause on all 3 ScaledObjects..."
for so in ${SERVICES}; do
  STATE=$(kubectl get scaledobject ${so} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}')
  [ "${STATE}" != "false" ] && \
    fail "${so} NOT active (annotation reads '${STATE}'). Aborting to protect Run 2 integrity."
  log "    ${so}: paused=false CONFIRMED (active)"
done
log "  KEDA fully active OK"

# ── STEP 3 — Wait for pre-scaling ────────────────────────────────────────────
echo ""
log "Step 3/6 — Waiting ${PRE_SCALE_WAIT}s for KEDA to pre-scale all 3 services..."
warn "  THIS IS THE KEY DIFFERENCE FROM RUN 1:"
warn "  Watch Panel 1 in Grafana — replicas climbing WITHOUT any Locust load"
warn "  http://${GRAFANA_IP}/d/${DASHBOARD_UID}"
echo ""

# Poll replica counts every 10 seconds during the pre-scale window
for i in $(seq 1 $((PRE_SCALE_WAIT / 10))); do
  sleep 10
  F=$(kubectl get deployment frontend -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  C=$(kubectl get deployment cartservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  P=$(kubectl get deployment productcatalogservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  echo "  [$(date '+%H:%M:%S')] Pre-scaling: frontend=${F} cartservice=${C} productcatalog=${P}"
done

# ── PRE-SCALE VERIFICATION GATE ──────────────────────────────────────────────
# This gate prevents a corrupted test — if KEDA failed to pre-scale (e.g.
# ML service down, ScaledObject misconfigured) we stop rather than run a
# test that would be identical to Run 1 and destroy the comparison.
F_FINAL=$(kubectl get deployment frontend -n ${NAMESPACE} \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
C_FINAL=$(kubectl get deployment cartservice -n ${NAMESPACE} \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
P_FINAL=$(kubectl get deployment productcatalogservice -n ${NAMESPACE} \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [ "${F_FINAL}" -lt ${PRE_SCALE_MIN_REPLICAS} ] || \
   [ "${C_FINAL}" -lt ${PRE_SCALE_MIN_REPLICAS} ] || \
   [ "${P_FINAL}" -lt ${PRE_SCALE_MIN_REPLICAS} ]; then
  warn "Pre-scaling incomplete after ${PRE_SCALE_WAIT}s:"
  warn "  frontend=${F_FINAL} cartservice=${C_FINAL} productcatalog=${P_FINAL}"
  warn "  Expected all >= ${PRE_SCALE_MIN_REPLICAS}. Waiting an extra 30s..."
  sleep 30
  F_FINAL=$(kubectl get deployment frontend -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  C_FINAL=$(kubectl get deployment cartservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  P_FINAL=$(kubectl get deployment productcatalogservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${F_FINAL}" -lt ${PRE_SCALE_MIN_REPLICAS} ] || \
     [ "${C_FINAL}" -lt ${PRE_SCALE_MIN_REPLICAS} ] || \
     [ "${P_FINAL}" -lt ${PRE_SCALE_MIN_REPLICAS} ]; then
    fail "Pre-scaling still incomplete: frontend=${F_FINAL} cartservice=${C_FINAL} \
productcatalog=${P_FINAL}. Aborting — Run 2 would be invalid."
  fi
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  PRE-SCALE CONFIRMED — THIS IS YOUR THESIS EVIDENCE         ║${NC}"
echo -e "${GREEN}║  frontend=${F_FINAL}  cartservice=${C_FINAL}  productcatalog=${P_FINAL}           ║${NC}"
echo -e "${GREEN}║  All 3 services pre-scaled BEFORE Locust starts             ║${NC}"
echo -e "${GREEN}║  Run 1 started all at 1 replica — that is the difference    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── STEP 4 — Start Locust ─────────────────────────────────────────────────────
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  OPEN GRAFANA NOW — SET TIME RANGE TO LAST 30 MINUTES       ║${NC}"
echo -e "${RED}║  http://${GRAFANA_IP}/d/${DASHBOARD_UID}          ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log "Step 4/6 — Starting Locust (identical profile to Run 1)..."
LOCUST_POD=$(kubectl get pod -n ${NAMESPACE} -l app=locust \
  -o jsonpath='{.items[0].metadata.name}')
[ -z "${LOCUST_POD}" ] && \
  fail "No Locust pod found in ${NAMESPACE}. Is locust deployment running?"

START_TIME=$(date '+%H:%M:%S')
START_EPOCH=$(date '+%s')
log "  Locust started at ${START_TIME}"
log "  Profile: ${PEAK_USERS} users | ${SPAWN_RATE}/sec spawn | ${TOTAL_DURATION}s total"

kubectl exec -n ${NAMESPACE} ${LOCUST_POD} -- \
  locust \
  -f /locust/locustfile.py \
  --host http://frontend:80 \
  --headless \
  --users ${PEAK_USERS} \
  --spawn-rate ${SPAWN_RATE} \
  --run-time ${TOTAL_DURATION}s \
  --csv /tmp/run2 \
  --only-summary &
LOCUST_PID=$!

# ── STEP 5 — Progress reporting ───────────────────────────────────────────────
log "Step 5/6 — Load test running..."
echo ""
warn "▶ RAMP PHASE — 0 → ${PEAK_USERS} users over ${RAMP_DURATION}s"
warn "  Pods are ALREADY scaled. CPU should stay flat. No reactive lag."

for i in $(seq 30 30 ${RAMP_DURATION}); do
  sleep 30
  remaining=$((RAMP_DURATION - i))
  REPLICAS=$(kubectl get deployment frontend -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  [ ${remaining} -gt 0 ] && \
    echo "  [$(date '+%H:%M:%S')] Ramping: ${i}s / ${RAMP_DURATION}s | frontend ready: ${REPLICAS}"
done

echo ""
warn "▶ HOLD PHASE — ${PEAK_USERS} users for ${HOLD_DURATION}s"
warn "  Compare Panel 1 vs Run 1: replicas already at ceiling, not climbing"
warn "  Compare Panel 3 vs Run 1: CPU flat per pod, not spiking"
warn "  Compare Panel 2 vs Run 1: no gap between desired and ready"

for i in $(seq 60 60 ${HOLD_DURATION}); do
  sleep 60
  remaining=$((HOLD_DURATION - i))
  F=$(kubectl get deployment frontend -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  C=$(kubectl get deployment cartservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  P=$(kubectl get deployment productcatalogservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  echo "  [$(date '+%H:%M:%S')] Holding: frontend=${F} cartservice=${C} productcatalog=${P} | ${remaining}s remaining"
done

wait ${LOCUST_PID} 2>/dev/null || true
STOP_TIME=$(date '+%H:%M:%S')
STOP_EPOCH=$(date '+%s')

echo ""
log "  Load test complete"
log "  Started : ${START_TIME}"
log "  Stopped : ${STOP_TIME}"
log "  Duration: $((STOP_EPOCH - START_EPOCH))s"

# ── CSV RETRIEVAL ─────────────────────────────────────────────────────────────
log "  Retrieving Locust CSV results from pod..."
mkdir -p ../results

kubectl cp \
  ${NAMESPACE}/${LOCUST_POD}:/tmp/run2_stats.csv \
  ../results/run2_stats.csv 2>/dev/null && \
  log "    Saved: results/run2_stats.csv" || \
  warn "    run2_stats.csv not found"

kubectl cp \
  ${NAMESPACE}/${LOCUST_POD}:/tmp/run2_stats_history.csv \
  ../results/run2_stats_history.csv 2>/dev/null && \
  log "    Saved: results/run2_stats_history.csv" || \
  warn "    run2_stats_history.csv not found"

# ── GRAFANA SCREENSHOT PROMPT ─────────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  CAPTURE GRAFANA SCREENSHOTS NOW (Run 2 — KEDA Predictive)  ║${NC}"
echo -e "${RED}║  URL: http://${GRAFANA_IP}/d/${DASHBOARD_UID}    ║${NC}"
echo -e "${RED}║  Time range: ${START_TIME} → ${STOP_TIME}                        ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  CAPTURE ALL 7 PANELS — key evidence vs Run 1:              ║${NC}"
echo -e "${RED}║  Panel 1: Replicas ALREADY at ceiling before load            ║${NC}"
echo -e "${RED}║  Panel 2: Zero gap between desired and ready                 ║${NC}"
echo -e "${RED}║  Panel 3: Flat CPU curve — load absorbed by pre-scaled pods  ║${NC}"
echo -e "${RED}║  Panel 7: predicted_rps crossed threshold BEFORE Locust      ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Press Enter when all screenshots are saved to continue to cleanup..."

# ── STEP 6 — Cleanup ─────────────────────────────────────────────────────────
log "Step 6/6 — Post-run cleanup..."

# Re-suspend KEDA — safe resting state, matches gke-stop expectations
for so in ${SERVICES}; do
  kubectl annotate scaledobject ${so} -n ${NAMESPACE} \
    autoscaling.keda.sh/paused="true" --overwrite
done
sleep 10

# Verify all ScaledObjects are back to suspended
log "  Verifying KEDA re-suspension..."
for so in ${SERVICES}; do
  STATE=$(kubectl get scaledobject ${so} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}')
  log "    ${so}: paused=${STATE}"
done

# Scale back to 1 replica — clean resting state
kubectl scale deployment frontend cartservice productcatalogservice \
  -n ${NAMESPACE} --replicas=1
log "  All services scaled to 1 replica OK"

# ── FINAL SUMMARY ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  RUN 2 COMPLETE — KEDA PREDICTIVE EVIDENCE CAPTURED         ║${NC}"
echo -e "${GREEN}║  CSV saved to: results/run2_stats.csv                       ║${NC}"
echo -e "${GREEN}║  KEDA re-suspended. Services at 1 replica.                  ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║  NEXT STEPS:                                                 ║${NC}"
echo -e "${GREEN}║  1. Commit results/ to Git: git add results/ && git push    ║${NC}"
echo -e "${GREEN}║  2. Run gke-stop to stop billing                            ║${NC}"
echo -e "${GREEN}║  3. Compare run1_stats.csv vs run2_stats.csv for report     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
