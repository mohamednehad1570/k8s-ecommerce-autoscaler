#!/bin/bash
# run2-keda-predictive.sh — Phase 9 Run 2: KEDA predictive (3 services)
# Usage: bash scripts/run2-keda-predictive.sh
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"; }

NAMESPACE="online-boutique"
PEAK_USERS=200
SPAWN_RATE=3
RAMP_DURATION=180
HOLD_DURATION=420
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))

echo ""
echo -e "${BLUE}=== PHASE 9 RUN 2: KEDA PREDICTIVE SCALING (3 services) ===${NC}"
echo -e "${BLUE}=== Peak users: ${PEAK_USERS} | Duration: ${TOTAL_DURATION}s (10 min) ===${NC}"
echo ""

log "Step 1/6 - Removing HPAs if present..."
kubectl delete hpa frontend-hpa-baseline cartservice-hpa-baseline \
  productcatalogservice-hpa-baseline -n ${NAMESPACE} --ignore-not-found
sleep 5
log "HPAs absent OK"

log "Step 2/6 - Unsuspending all 3 KEDA ScaledObjects..."
kubectl patch scaledobject frontend-scaledobject \
  -n ${NAMESPACE} --type merge -p '{"spec":{"paused":false}}'
kubectl patch scaledobject cartservice-scaledobject \
  -n ${NAMESPACE} --type merge -p '{"spec":{"paused":false}}'
kubectl patch scaledobject productcatalogservice-scaledobject \
  -n ${NAMESPACE} --type merge -p '{"spec":{"paused":false}}'
sleep 15
log "KEDA active OK"

log "Step 3/6 - Waiting 90s for KEDA to pre-scale all 3 services..."
warn "Watch Grafana Panel 1 - all 3 services should scale up BEFORE load"
for i in $(seq 1 9); do
  sleep 10
  F=$(kubectl get deployment frontend -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  C=$(kubectl get deployment cartservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  P=$(kubectl get deployment productcatalogservice -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  log "  [${i}0s] frontend=${F} cartservice=${C} productcatalog=${P}"
done

echo ""
warn "KEY METRIC: All 3 services pre-scaled BEFORE load arrives"
warn "Run 1 started all at 1 replica - this difference is your thesis evidence"
echo ""

GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log "Step 4/6 - Starting Locust (identical profile to Run 1)..."
warn "GRAFANA: http://${GRAFANA_IP}"

LOCUST_POD=$(kubectl get pod -n ${NAMESPACE} -l app=locust \
  -o jsonpath='{.items[0].metadata.name}')
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
  --only-summary &

LOCUST_PID=$!

log "Step 5/6 - Load test running..."
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
warn "Compare: lower errors, lower latency vs Run 1"
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
echo -e "${RED}  KEY vs Run 1: all 3 services pre-scaled, dramatically fewer errors${NC}"
echo ""
read -p "Press Enter when screenshots saved..."

log "Step 6/6 - Cleaning up..."
kubectl patch scaledobject frontend-scaledobject \
  -n ${NAMESPACE} --type merge -p '{"spec":{"paused":true}}'
kubectl patch scaledobject cartservice-scaledobject \
  -n ${NAMESPACE} --type merge -p '{"spec":{"paused":true}}'
kubectl patch scaledobject productcatalogservice-scaledobject \
  -n ${NAMESPACE} --type merge -p '{"spec":{"paused":true}}'
kubectl scale deployment frontend cartservice productcatalogservice \
  -n ${NAMESPACE} --replicas=1
log "All KEDA ScaledObjects re-suspended. All services at 1 replica."
log "Run gke-stop to stop billing."
