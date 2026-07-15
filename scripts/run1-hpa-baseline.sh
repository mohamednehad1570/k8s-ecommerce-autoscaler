#!/bin/bash
# run1-hpa-baseline.sh — Phase 9 Run 1: Reactive HPA baseline (3 services)
# FIXED: uses the correct KEDA pause annotation (autoscaling.keda.sh/paused)
# instead of the non-existent spec.paused field, and verifies the pause
# actually took effect before proceeding — no silent failures.
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"; }
fail() { echo -e "${RED}[$(date '+%H:%M:%S')] FATAL: $1${NC}"; exit 1; }

NAMESPACE="online-boutique"
SERVICES="frontend-scaledobject cartservice-scaledobject productcatalogservice-scaledobject"
PEAK_USERS=200
SPAWN_RATE=3
RAMP_DURATION=180
HOLD_DURATION=420
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))

echo ""
echo -e "${BLUE}=== PHASE 9 RUN 1: HPA REACTIVE BASELINE (3 services) ===${NC}"
echo -e "${BLUE}=== Peak users: ${PEAK_USERS} | Duration: ${TOTAL_DURATION}s (10 min) ===${NC}"
echo ""

log "Step 1/7 - Removing any leftover HPAs..."
kubectl delete hpa frontend-hpa-baseline cartservice-hpa-baseline \
  productcatalogservice-hpa-baseline -n ${NAMESPACE} --ignore-not-found
sleep 5
log "HPAs clean OK"

log "Step 2/7 - Suspending all 3 KEDA ScaledObjects (annotation-based)..."
for so in ${SERVICES}; do
  kubectl annotate scaledobject ${so} -n ${NAMESPACE} \
    autoscaling.keda.sh/paused="true" --overwrite
done
sleep 10

# HARD VERIFICATION — this is the fix for the silent-failure bug.
# We read back the annotation from the live cluster and refuse to proceed
# unless every single ScaledObject actually shows paused=true.
log "Verifying pause took effect on all 3 ScaledObjects..."
for so in ${SERVICES}; do
  STATE=$(kubectl get scaledobject ${so} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}')
  if [ "${STATE}" != "true" ]; then
    fail "${so} is NOT paused (annotation reads '${STATE}'). Aborting before Run 1 is corrupted."
  fi
  log "  ${so}: paused=true CONFIRMED"
done

kubectl delete hpa keda-hpa-frontend-scaledobject \
  keda-hpa-cartservice-scaledobject \
  keda-hpa-productcatalogservice-scaledobject \
  -n ${NAMESPACE} --ignore-not-found
sleep 5
log "KEDA genuinely suspended OK"

log "Step 3/7 - Scaling all 3 services to 1 replica..."
kubectl scale deployment frontend cartservice productcatalogservice \
  -n ${NAMESPACE} --replicas=1
kubectl rollout status deployment/frontend -n ${NAMESPACE} --timeout=120s
kubectl rollout status deployment/cartservice -n ${NAMESPACE} --timeout=120s
kubectl rollout status deployment/productcatalogservice -n ${NAMESPACE} --timeout=120s
log "All services at 1 replica OK"

log "Step 4/7 - Applying HPAs for all 3 services..."
kubectl apply -f scripts/manifests/frontend-hpa.yaml
kubectl apply -f scripts/manifests/cartservice-hpa.yaml
kubectl apply -f scripts/manifests/productcatalogservice-hpa.yaml
sleep 10
log "HPAs active OK"

GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log "Step 5/7 - Starting Locust..."
warn "GRAFANA: Open dashboard NOW at http://${GRAFANA_IP}"

LOCUST_POD=$(kubectl get pod -n ${NAMESPACE} -l app=locust \
  -o jsonpath='{.items[0].metadata.name}')
START_TIME=$(date '+%H:%M:%S')
log "Locust starting at ${START_TIME} - ${PEAK_USERS} users, ${SPAWN_RATE}/sec"

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

LOCUST_PID=$!

log "Step 6/7 - Load test running..."
warn "RAMP PHASE (0 to ${PEAK_USERS} users over ${RAMP_DURATION}s):"
for i in $(seq 30 30 ${RAMP_DURATION}); do
  sleep 30
  elapsed=$i
  remaining=$((RAMP_DURATION - elapsed))
  if [ ${remaining} -gt 0 ]; then
    echo "  [$(date '+%H:%M:%S')] Ramping... ${elapsed}s elapsed, ${remaining}s until peak"
  fi
done

echo ""
warn "HOLD PHASE (${PEAK_USERS} users for ${HOLD_DURATION}s):"
warn "Watch Grafana - all 3 services scaling reactively"
for i in $(seq 60 60 ${HOLD_DURATION}); do
  sleep 60
  elapsed=$i
  remaining=$((HOLD_DURATION - elapsed))
  if [ ${remaining} -gt 0 ]; then
    echo "  [$(date '+%H:%M:%S')] Holding... ${elapsed}s elapsed, ${remaining}s remaining"
  fi
done

wait ${LOCUST_PID} 2>/dev/null || true

STOP_TIME=$(date '+%H:%M:%S')
log "Load test complete"
log "  Started: ${START_TIME}"
log "  Stopped: ${STOP_TIME}"
echo ""

echo -e "${RED}=== CAPTURE GRAFANA SCREENSHOTS NOW ===${NC}"
echo -e "${RED}  URL: http://${GRAFANA_IP}${NC}"
echo -e "${RED}  Time range: ${START_TIME} to ${STOP_TIME}${NC}"
echo -e "${RED}  Screenshot all 4 panels + terminal error report${NC}"
echo ""
read -p "Press Enter when screenshots saved..."

log "Step 7/7 - Cleaning up..."
kubectl delete hpa frontend-hpa-baseline cartservice-hpa-baseline \
  productcatalogservice-hpa-baseline -n ${NAMESPACE} --ignore-not-found
kubectl scale deployment frontend cartservice productcatalogservice \
  -n ${NAMESPACE} --replicas=1
warn "KEDA remains genuinely suspended (verified). Run run2-keda-predictive.sh next."
log "Run 1 complete."
