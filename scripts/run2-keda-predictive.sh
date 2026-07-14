
#!/bin/bash
# run2-keda-predictive.sh — Phase 9 Run 2: KEDA + Holt-Winters predictive
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
FRONTEND_DEPLOYMENT="frontend"
SCALEDOBJECT_NAME="frontend-scaledobject"
PEAK_USERS=200
SPAWN_RATE=3
RAMP_DURATION=180
HOLD_DURATION=420
TOTAL_DURATION=$((RAMP_DURATION + HOLD_DURATION))

echo ""
echo -e "${BLUE}=== PHASE 9 RUN 2: KEDA PREDICTIVE SCALING ===${NC}"
echo -e "${BLUE}=== Peak users: ${PEAK_USERS} | Duration: ${TOTAL_DURATION}s (10 min) ===${NC}"
echo ""

log "Step 1/6 - Removing HPA if present..."
kubectl delete hpa frontend-hpa-baseline -n ${NAMESPACE} --ignore-not-found
log "HPA absent OK"

log "Step 2/6 - Unsuspending KEDA ScaledObject..."
kubectl patch scaledobject frontend-scaledobject cartservice-scaledobject productcatalogservice-scaledobject \
  -n ${NAMESPACE} \
  --type merge \
  -p '{"spec":{"paused":false}}'
log "KEDA ScaledObject active OK"

log "Step 3/6 - Waiting 60s for KEDA to pre-scale based on predicted_rps..."
warn "Watch Grafana Panel 1 - replicas should increase BEFORE load starts"
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
echo ""
warn "KEY METRIC: frontend has ${PRE_SCALE_REPLICAS} replica(s) BEFORE any load arrives"
warn "Run 1 started with 1 replica - this difference is your thesis evidence"
echo ""

GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log "Step 4/6 - Starting Locust (identical profile to Run 1)..."
warn "GRAFANA: http://${GRAFANA_IP} - note start time for comparison with Run 1"

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
  --only-summary &

LOCUST_PID=$!

log "Step 5/6 - Load test running..."
echo ""
warn "RAMP PHASE (0 to ${PEAK_USERS} users over ${RAMP_DURATION}s):"
for i in $(seq 30 30 ${RAMP_DURATION}); do
  sleep 30
  elapsed=$i
  remaining=$((RAMP_DURATION - elapsed))
  if [ ${remaining} -gt 0 ]; then
    echo -e "  [$(date '+%H:%M:%S')] Ramping... ${elapsed}s elapsed, ${remaining}s until peak"
  fi
done

echo ""
warn "HOLD PHASE (${PEAK_USERS} users for ${HOLD_DURATION}s) - compare vs Run 1:"
for i in $(seq 60 60 ${HOLD_DURATION}); do
  sleep 60
  elapsed=$i
  remaining=$((HOLD_DURATION - elapsed))
  if [ ${remaining} -gt 0 ]; then
    echo -e "  [$(date '+%H:%M:%S')] Holding... ${elapsed}s elapsed, ${remaining}s remaining"
  fi
done

wait ${LOCUST_PID} 2>/dev/null || true

STOP_TIME=$(date '+%H:%M:%S')
log "Load test complete"
log "  Started:  ${START_TIME}"
log "  Stopped:  ${STOP_TIME}"
echo ""

echo -e "${RED}=== CAPTURE GRAFANA SCREENSHOTS NOW ===${NC}"
echo -e "${RED}  Grafana: http://${GRAFANA_IP}${NC}"
echo -e "${RED}  Time range: ${START_TIME} to ${STOP_TIME}${NC}"
echo -e "${RED}  KEY vs Run 1: replicas already elevated, lower CPU spike, smaller error gap${NC}"
echo ""
read -p "Press Enter when screenshots are saved..."

log "Cleaning up Run 2..."
kubectl patch scaledobject frontend-scaledobject cartservice-scaledobject productcatalogservice-scaledobject \
  -n ${NAMESPACE} \
  --type merge \
  -p '{"spec":{"paused":true}}'
kubectl scale deployment ${FRONTEND_DEPLOYMENT} -n ${NAMESPACE} --replicas=1
log "KEDA re-suspended. Frontend at 1. Resting state restored."
log "Run 2 complete. Run gke-stop to stop billing."
