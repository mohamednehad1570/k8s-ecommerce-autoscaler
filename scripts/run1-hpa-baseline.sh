
#!/bin/bash
# run1-hpa-baseline.sh — Phase 9 Run 1: Reactive HPA baseline
# Usage: bash scripts/run1-hpa-baseline.sh
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
echo -e "${BLUE}=== PHASE 9 RUN 1: HPA REACTIVE BASELINE ===${NC}"
echo -e "${BLUE}=== Peak users: ${PEAK_USERS} | Duration: ${TOTAL_DURATION}s (10 min) ===${NC}"
echo ""

log "Step 1/6 - Suspending KEDA ScaledObject..."
kubectl patch scaledobject ${SCALEDOBJECT_NAME} \
  -n ${NAMESPACE} \
  --type merge \
  -p '{"spec":{"paused":true}}'
sleep 5

log "Step 2/6 - Scaling frontend to 1 replica..."
kubectl scale deployment ${FRONTEND_DEPLOYMENT} \
  -n ${NAMESPACE} \
  --replicas=1
kubectl rollout status deployment/${FRONTEND_DEPLOYMENT} -n ${NAMESPACE} --timeout=120s
log "Frontend at 1 replica OK"

log "Step 3/6 - Applying HPA (CPU 50% threshold)..."
kubectl apply -f kubernetes/locust/frontend-hpa.yaml
sleep 10
log "HPA active OK"

GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log "Step 4/6 - Starting Locust load test..."
warn "GRAFANA: Open dashboard NOW at http://${GRAFANA_IP}"

LOCUST_POD=$(kubectl get pod -n ${NAMESPACE} -l app=locust -o jsonpath='{.items[0].metadata.name}')
START_TIME=$(date '+%H:%M:%S')
log "Locust starting at ${START_TIME} - target: ${PEAK_USERS} users, spawn rate: ${SPAWN_RATE}/sec"

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
warn "HOLD PHASE (${PEAK_USERS} users for ${HOLD_DURATION}s) - watch Grafana for HPA scaling:"
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
echo -e "${RED}  Screenshot all 4 panels${NC}"
echo ""
read -p "Press Enter when screenshots are saved..."

log "Cleaning up Run 1..."
kubectl delete hpa frontend-hpa-baseline -n ${NAMESPACE} --ignore-not-found
kubectl scale deployment ${FRONTEND_DEPLOYMENT} -n ${NAMESPACE} --replicas=1
warn "KEDA remains suspended. Run run2-keda-predictive.sh next."
log "Run 1 complete."
