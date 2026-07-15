#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# run1-hpa-baseline.sh — Phase 9 Run 1: Reactive HPA Baseline
#
# PURPOSE:
#   Establishes the reactive autoscaling baseline using Kubernetes HPA (CPU 50%).
#   KEDA is suspended so only HPA controls scaling. Services start at 1 replica
#   and scale up reactively AFTER CPU threshold is breached by Locust load.
#
# PROFILE:
#   200 users | 3 users/sec spawn | 3 min ramp + 7 min hold = 10 min total
#
# WHAT TO WATCH IN GRAFANA (http://35.205.175.90):
#   Panel 1 — Replicas climb AFTER load starts (reactive lag visible)
#   Panel 2 — Gap between desired and ready = scaling lag window
#   Panel 3 — CPU spikes before HPA reacts
#   Panel 6 — Autoscaler decision timestamp (compare to Locust start time)
#
# SEQUENCE:
#   run1 (HPA baseline) → screenshots → run2 (KEDA predictive) → screenshots
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
NAMESPACE="online-boutique"                          # namespace where boutique runs
GRAFANA_IP="35.205.175.90"                           # confirmed LoadBalancer IP
DASHBOARD_UID="phase9-autoscaling"                   # Grafana dashboard UID
SERVICES="frontend-scaledobject cartservice-scaledobject productcatalogservice-scaledobject"
DEPLOYMENTS="frontend cartservice productcatalogservice"
PEAK_USERS=200                                       # maximum concurrent Locust users
SPAWN_RATE=3                                         # users added per second during ramp
RAMP_DURATION=180                                    # seconds to ramp from 0 to PEAK_USERS
HOLD_DURATION=420                                    # seconds to hold at PEAK_USERS
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))   # total Locust run time in seconds

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     PHASE 9 — RUN 1: HPA REACTIVE BASELINE                  ║${NC}"
echo -e "${BLUE}║     Peak: ${PEAK_USERS} users | Spawn: ${SPAWN_RATE}/sec | Duration: ${TOTAL_DURATION}s       ║${NC}"
echo -e "${BLUE}║     Grafana: http://${GRAFANA_IP}                      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── PRE-RUN STATE SNAPSHOT ────────────────────────────────────────────────────
info "PRE-RUN STATE SNAPSHOT:"
info "  Deployment replicas before run:"
for d in ${DEPLOYMENTS}; do
  READY=$(kubectl get deployment ${d} -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl get deployment ${d} -n ${NAMESPACE} \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  info "    ${d}: ${READY}/${DESIRED} ready"
done
info "  ML predicted_rps (current):"
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
info "  KEDA ScaledObject states:"
for so in ${SERVICES}; do
  STATE=$(kubectl get scaledobject ${so} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}' \
    2>/dev/null || echo "unknown")
  info "    ${so}: paused=${STATE}"
done
echo ""

# ── STEP 1 — Clean any leftover HPAs ─────────────────────────────────────────
log "Step 1/7 — Removing any leftover HPAs from previous runs..."
kubectl delete hpa \
  frontend-hpa-baseline \
  cartservice-hpa-baseline \
  productcatalogservice-hpa-baseline \
  -n ${NAMESPACE} --ignore-not-found   # --ignore-not-found: no error if already absent
sleep 5
log "  HPAs clean OK"

# ── STEP 2 — Suspend KEDA (annotation-based, hard-verified) ──────────────────
log "Step 2/7 — Suspending all 3 KEDA ScaledObjects..."
for so in ${SERVICES}; do
  # annotation autoscaling.keda.sh/paused=true tells KEDA operator to stop
  # managing this ScaledObject — it will no longer adjust replica counts
  kubectl annotate scaledobject ${so} -n ${NAMESPACE} \
    autoscaling.keda.sh/paused="true" --overwrite
done
sleep 10

# Hard verification: read the annotation back from the live cluster.
# If any ScaledObject is not actually paused, abort immediately.
log "  Verifying pause on all 3 ScaledObjects..."
for so in ${SERVICES}; do
  STATE=$(kubectl get scaledobject ${so} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}')
  [ "${STATE}" != "true" ] && \
    fail "${so} NOT paused (reads '${STATE}'). Aborting to protect Run 1 integrity."
  log "    ${so}: paused=true CONFIRMED"
done

# Also delete any KEDA-managed HPAs that may still exist
kubectl delete hpa \
  keda-hpa-frontend-scaledobject \
  keda-hpa-cartservice-scaledobject \
  keda-hpa-productcatalogservice-scaledobject \
  -n ${NAMESPACE} --ignore-not-found
sleep 5
log "  KEDA fully suspended OK"

# ── STEP 3 — Scale all services to 1 replica ─────────────────────────────────
log "Step 3/7 — Scaling all 3 services to 1 replica (HPA start condition)..."
kubectl scale deployment frontend cartservice productcatalogservice \
  -n ${NAMESPACE} --replicas=1

# rollout status: blocks until the deployment reaches its desired state
# --timeout=120s: fail if not ready within 2 minutes
kubectl rollout status deployment/frontend -n ${NAMESPACE} --timeout=120s
kubectl rollout status deployment/cartservice -n ${NAMESPACE} --timeout=120s
kubectl rollout status deployment/productcatalogservice -n ${NAMESPACE} --timeout=120s
log "  All services at 1/1 ready OK"

# ── STEP 4 — Apply HPAs ───────────────────────────────────────────────────────
log "Step 4/7 — Applying HPA manifests (CPU 50%, max 8 replicas)..."
# manifests/ path is relative to the scripts/ directory where this script lives
kubectl apply -f scripts/manifests/frontend-hpa.yaml
kubectl apply -f scripts/manifests/cartservice-hpa.yaml
kubectl apply -f scripts/manifests/productcatalogservice-hpa.yaml
sleep 10

# Confirm HPAs are active
log "  HPA status:"
kubectl get hpa -n ${NAMESPACE} | grep -E "frontend|cartservice|productcatalog" \
  || warn "  HPAs not yet showing — may take a few seconds"
log "  HPAs active OK"

# ── STEP 5 — Start Locust ─────────────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  OPEN GRAFANA NOW — SET TIME RANGE TO LAST 30 MINUTES       ║${NC}"
echo -e "${RED}║  http://${GRAFANA_IP}/d/${DASHBOARD_UID}          ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log "Step 5/7 — Starting Locust load test..."

# Get the Locust pod name dynamically
LOCUST_POD=$(kubectl get pod -n ${NAMESPACE} -l app=locust \
  -o jsonpath='{.items[0].metadata.name}')
[ -z "${LOCUST_POD}" ] && fail "No Locust pod found in ${NAMESPACE}. Is locust deployment running?"

START_TIME=$(date '+%H:%M:%S')
START_EPOCH=$(date '+%s')   # epoch seconds — used for CSV timestamp
log "  Locust started at ${START_TIME}"
log "  Profile: ${PEAK_USERS} users | ${SPAWN_RATE}/sec spawn | ${TOTAL_DURATION}s total"

# Run Locust headlessly inside the pod
# --headless: no web UI, runs immediately
# --csv /tmp/run1: writes stats to /tmp/run1_stats.csv inside the pod
# --only-summary: suppresses per-request output, prints summary at end
# & : runs in background so we can print progress while it runs
kubectl exec -n ${NAMESPACE} ${LOCUST_POD} -- \
  locust \
  -f /locust/locustfile.py \
  --host http://frontend:80 \
  --headless \
  --users ${PEAK_USERS} \
  --spawn-rate ${SPAWN_RATE} \
  --run-time ${TOTAL_DURATION}s \
  --csv /tmp/run1 \
  --only-summary &
LOCUST_PID=$!   # save background process ID so we can wait for it later

# ── STEP 6 — Progress reporting ───────────────────────────────────────────────
log "Step 6/7 — Load test running..."
echo ""
warn "▶ RAMP PHASE — 0 → ${PEAK_USERS} users over ${RAMP_DURATION}s"
warn "  Watch Panel 3 (CPU) spike. HPA will NOT react yet — threshold not breached."

# Print progress every 30 seconds during ramp phase
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
warn "  Watch Panel 1: replicas climbing reactively. Panel 3: CPU under pressure."
warn "  This is the reactive lag — the core evidence for your thesis."

# Print replica counts every 60 seconds during hold phase
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

# Wait for Locust to finish
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
mkdir -p ../results    # create results/ directory at repo root level

# Copy CSV files out of the Locust pod before they can be lost on pod restart
kubectl cp \
  ${NAMESPACE}/${LOCUST_POD}:/tmp/run1_stats.csv \
  ../results/run1_stats.csv 2>/dev/null && \
  log "    Saved: results/run1_stats.csv" || \
  warn "    run1_stats.csv not found — Locust may not have written it yet"

kubectl cp \
  ${NAMESPACE}/${LOCUST_POD}:/tmp/run1_stats_history.csv \
  ../results/run1_stats_history.csv 2>/dev/null && \
  log "    Saved: results/run1_stats_history.csv" || \
  warn "    run1_stats_history.csv not found"

# ── GRAFANA SCREENSHOT PROMPT ─────────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  CAPTURE GRAFANA SCREENSHOTS NOW (Run 1 — HPA Baseline)     ║${NC}"
echo -e "${RED}║  URL: http://${GRAFANA_IP}/d/${DASHBOARD_UID}    ║${NC}"
echo -e "${RED}║  Time range: ${START_TIME} → ${STOP_TIME}                        ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  CAPTURE ALL 7 PANELS — key evidence:                       ║${NC}"
echo -e "${RED}║  Panel 1: Replicas climbing reactively after load            ║${NC}"
echo -e "${RED}║  Panel 2: Gap between desired and ready (scaling lag)        ║${NC}"
echo -e "${RED}║  Panel 3: CPU spike before HPA reacted                      ║${NC}"
echo -e "${RED}║  Panel 6: Timestamp when autoscaler made its decision        ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Press Enter when all screenshots are saved to continue to cleanup..."

# ── STEP 7 — Cleanup + cooldown ───────────────────────────────────────────────
log "Step 7/7 — Cleanup and cooldown before Run 2..."

# Remove HPAs — they must be gone before Run 2 starts
kubectl delete hpa \
  frontend-hpa-baseline \
  cartservice-hpa-baseline \
  productcatalogservice-hpa-baseline \
  -n ${NAMESPACE} --ignore-not-found
log "  HPAs removed OK"

# Scale back to 1 replica so Run 2 starts from the same baseline
kubectl scale deployment frontend cartservice productcatalogservice \
  -n ${NAMESPACE} --replicas=1

# Wait until all 3 services are confirmed at 1/1 before Run 2 can begin
# This is the cooldown gate — prevents Run 2 from inheriting Run 1's state
log "  Waiting for all services to settle at 1/1 ready (cooldown)..."
for d in frontend cartservice productcatalogservice; do
  kubectl rollout status deployment/${d} -n ${NAMESPACE} --timeout=120s
done

# Final confirmation
log "  POST-RUN STATE:"
for d in ${DEPLOYMENTS}; do
  READY=$(kubectl get deployment ${d} -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  log "    ${d}: ${READY}/1 ready"
done

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  RUN 1 COMPLETE — HPA BASELINE CAPTURED                     ║${NC}"
echo -e "${GREEN}║  CSV saved to: results/run1_stats.csv                       ║${NC}"
echo -e "${GREEN}║  KEDA still suspended. Services at 1 replica. Ready for Run 2.║${NC}"
echo -e "${GREEN}║  Next: bash scripts/run2-keda-predictive.sh                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
