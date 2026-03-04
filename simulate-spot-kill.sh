#!/usr/bin/env bash
# ============================================================
#  simulate-spot-kill.sh
#  Waits 2 minutes, then drains the node the job pod runs on
#  to simulate an EC2 Spot instance interruption.
#  Karpenter provisions a new node; the job resumes from its
#  last ConfigMap checkpoint.
# ============================================================
set -euo pipefail

NS="live-migration"
JOB="spot-resilient-job"
SEP="================================================================"

# ── helpers ──────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

get_job_pod()  { kubectl get pods -n $NS -l app=spot-resilient-job \
                   --field-selector=status.phase=Running \
                   -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
get_pod_node() { kubectl get pod "$1" -n $NS \
                   -o jsonpath='{.spec.nodeName}' 2>/dev/null; }

# ── Step 1: wait for job pod to be Running ────────────────────────────
echo ""
bold "$SEP"
bold "  SPOT INTERRUPTION SIMULATION"
bold "$SEP"
echo ""
info "Waiting for job pod to reach Running state..."
for i in $(seq 1 60); do
    POD=$(get_job_pod) && [ -n "$POD" ] && break
    echo "  [$i] pod not yet Running — waiting 5s..."
    sleep 5
done

if [ -z "${POD:-}" ]; then
    echo "ERROR: job pod not found after 5 minutes. Is the job deployed?"
    exit 1
fi

NODE=$(get_pod_node "$POD")
ok "Job pod is Running"
echo "  Pod  : $POD"
echo "  Node : $NODE"
echo ""

# ── Step 2: tail logs for 2 minutes ──────────────────────────────────
bold "$SEP"
bold "  Watching job for 2 minutes before simulating Spot kill..."
bold "$SEP"
echo ""

kubectl logs -f "$POD" -n $NS &
LOG_PID=$!
sleep 120
kill $LOG_PID 2>/dev/null || true
echo ""

# Confirm pod is still on the same node
CURRENT_NODE=$(get_pod_node "$POD" 2>/dev/null || echo "gone")
if [ "$CURRENT_NODE" != "$NODE" ]; then
    warn "Pod already moved to $CURRENT_NODE — node may have been replaced by Karpenter."
    NODE=$CURRENT_NODE
fi

# ── Step 3: print current checkpoint ─────────────────────────────────
echo ""
bold "$SEP"
bold "  PRE-KILL CHECKPOINT STATE"
bold "$SEP"
kubectl get configmap spot-job-checkpoint -n $NS \
    -o jsonpath='{.data.state}' 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.loads(sys.stdin.read())
    print(f'  elapsed_s     : {d.get(\"elapsed_s\",0)}s / 600s')
    print(f'  ticks done    : {d.get(\"ticks\",0)}')
    print(f'  interruptions : {d.get(\"interruptions\",0)}')
    print(f'  last node     : {d.get(\"last_node\",\"?\")}'  )
except:
    print('  (no checkpoint yet)')
" 2>/dev/null || echo "  (checkpoint not written yet)"
echo ""

# ── Step 4: simulate Spot kill ────────────────────────────────────────
echo ""
bold "$SEP"
bold "  ⚡  SIMULATING SPOT INSTANCE INTERRUPTION"
bold "  Target node: $NODE"
bold "$SEP"
echo ""

info "Step 4a: Cordoning node (marking unschedulable)..."
kubectl cordon "$NODE"
ok "Node cordoned — no new pods will land here"

echo ""
info "Step 4b: Draining node (evicting all pods, simulating instance termination)..."
echo "  (this may take 30-60 seconds)"
kubectl drain "$NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=90s \
    --grace-period=5 2>&1 | sed 's/^/  /'

ok "Node drained — all pods evicted"
echo ""

# ── Step 5: watch Karpenter + job recovery ────────────────────────────
bold "$SEP"
bold "  WATCHING RECOVERY (Karpenter + Job Controller)"
bold "$SEP"
echo ""
info "Waiting for job pod to restart on a new node..."

WAIT=0
NEW_POD=""
NEW_NODE=""
while true; do
    sleep 5
    WAIT=$((WAIT+5))

    # Find any pod for this job (might be a new pod name)
    ALL_PODS=$(kubectl get pods -n $NS -l app=spot-resilient-job \
        -o jsonpath='{range .items[*]}{.metadata.name}/{.status.phase}/{.spec.nodeName} {end}' 2>/dev/null)
    echo "  [+${WAIT}s] pods: ${ALL_PODS:-none}"

    # Look for a Running pod on a different node
    for entry in $ALL_PODS; do
        P=$(echo $entry | cut -d/ -f1)
        S=$(echo $entry | cut -d/ -f2)
        N=$(echo $entry | cut -d/ -f3)
        if [ "$S" = "Running" ] && [ "$N" != "$NODE" ] && [ -n "$N" ]; then
            NEW_POD=$P
            NEW_NODE=$N
            break 2
        fi
    done

    # Check if Karpenter launched a new node
    NEW_NODES=$(kubectl get nodes --field-selector=spec.unschedulable!=true \
        -o jsonpath='{range .items[*]}{.metadata.name} {end}' 2>/dev/null | \
        tr ' ' '\n' | grep -v "^$NODE$" | grep -v "^$" | head -5 || true)
    echo "  [+${WAIT}s] ready nodes: $(echo $NEW_NODES | tr '\n' ' ')"

    if [ $WAIT -ge 300 ]; then
        warn "Timed out after 5 minutes — check cluster manually"
        break
    fi
done

if [ -n "$NEW_POD" ]; then
    echo ""
    ok "Job resumed on new node!"
    echo "  New pod  : $NEW_POD"
    echo "  New node : $NEW_NODE"
    echo "  Original : $NODE (drained/simulated-terminated)"
    echo ""

    # Print checkpoint state after resume
    bold "$SEP"
    bold "  POST-RESUME CHECKPOINT STATE"
    bold "$SEP"
    sleep 5
    kubectl get configmap spot-job-checkpoint -n $NS \
        -o jsonpath='{.data.state}' 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.loads(sys.stdin.read())
    print(f'  elapsed_s     : {d.get(\"elapsed_s\",0)}s / 600s  ✅ preserved')
    print(f'  ticks done    : {d.get(\"ticks\",0)}')
    print(f'  interruptions : {d.get(\"interruptions\",0)}  ⚡')
    print(f'  last node     : {d.get(\"last_node\",\"?\")}'  )
except:
    print('  (reading...)')
" 2>/dev/null
    echo ""

    # Tail the new pod's logs until done
    bold "$SEP"
    bold "  TAILING JOB LOGS ON NEW NODE (Ctrl+C to stop)"
    bold "$SEP"
    echo ""
    kubectl logs -f "$NEW_POD" -n $NS
fi

# ── Step 6: uncordon the drained node ─────────────────────────────────
echo ""
bold "$SEP"
bold "  CLEANUP — uncordoning $NODE"
bold "$SEP"
kubectl uncordon "$NODE" && ok "Node uncordoned — available for scheduling again"
echo ""
info "Demo complete. The job will finish its remaining work on $NEW_NODE."
echo ""
