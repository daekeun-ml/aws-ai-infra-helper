#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# 4.ensure-workshop-capacity.sh
#
# Ensures each worker node can schedule enough pods for the workshop.
#
# Why this exists:
#   On SageMaker HyperPod EKS, the node bootstrap (nodeadm drop-in) pins
#   kubelet maxPods to a very low value (e.g. 14 on ml.g5.2xlarge), even
#   though the base kubelet config and the instance's IP budget allow far
#   more. With only ~14 slots, mandatory system/HyperPod DaemonSets fill the
#   node and workshop training/inference pods fail to schedule.
#
#   The PRIMARY, non-destructive fix is to raise kubelet maxPods on each node
#   (default 28 — the IP budget for the 2 ENIs HyperPod attaches to
#   ml.g5.2xlarge: 2 x (15-1) = 28). This frees real slots without deleting
#   anything.
#
#   OPTIONAL: freeing idle/non-essential pods (the old behavior) is now
#   opt-in via --free-idle-pods, because (a) raising maxPods usually makes it
#   unnecessary, and (b) most of those components are EKS-managed add-ons that
#   the add-on controller recreates, so the effect is only temporary.
#
# IMPORTANT — this change is NOT permanent:
#   maxPods is set on the live node and is LOST when HyperPod reprovisions or
#   health-replaces the node (it reverts to the bootstrap value). Re-run this
#   script after node replacement, or bake it into the HyperPod lifecycle
#   config for a durable change. A backup of the original drop-in is saved on
#   each node, and --revert restores it.
#
# Usage:
#   ./4.ensure-workshop-capacity.sh                 # raise maxPods to 28 on all nodes
#   ./4.ensure-workshop-capacity.sh --max-pods 40   # custom target
#   ./4.ensure-workshop-capacity.sh --free-idle-pods # also run optional cleanup
#   ./4.ensure-workshop-capacity.sh --revert        # restore original maxPods
#   ./4.ensure-workshop-capacity.sh --yes           # no confirmation prompt

set -uo pipefail

MAX_PODS=28
FREE_IDLE_PODS=false
REVERT=false
ASSUME_YES=false
# AL2023 nodeadm writes the authoritative maxPods override here.
DROPIN="/host/etc/kubernetes/kubelet/config.json.d/40-nodeadm.conf"
# Minimal image used by `kubectl debug node` to reach the host filesystem.
DEBUG_IMAGE="public.ecr.aws/amazonlinux/amazonlinux:2023"

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-pods) MAX_PODS="$2"; shift 2 ;;
        --free-idle-pods) FREE_IDLE_PODS=true; shift ;;
        --revert) REVERT=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        -h|--help) usage ;;
        *) echo "❌ Unknown option: $1"; echo "   run with --help"; exit 1 ;;
    esac
done

if ! command -v kubectl &>/dev/null; then
    echo "❌ [ERROR] kubectl not found. Run ./2.setup-eks-access.sh first."
    exit 1
fi
if ! kubectl get nodes &>/dev/null; then
    echo "❌ [ERROR] Cannot reach the cluster. Run ./2.setup-eks-access.sh first."
    exit 1
fi

confirm() {
    $ASSUME_YES && return 0
    read -r -p "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# Run a script on the host of $node via an ephemeral debug pod.
# We create the pod detached (--attach=false) and read its logs after it
# finishes, because attaching over a non-TTY pipe drops the pod's stdout.
run_on_node() {
    local node="$1" inner="$2" out pod
    out=$(kubectl debug "node/${node}" --image="$DEBUG_IMAGE" --profile=sysadmin \
        --attach=false -- bash -c "$inner" 2>&1)
    pod=$(echo "$out" | grep -oE "node-debugger-${node}-[a-z0-9]+" | head -1)
    if [ -z "$pod" ]; then
        echo "    ⚠️  failed to create debug pod on ${node}: ${out}"
        return 1
    fi
    # kubelet restart can briefly disrupt the API path to the pod; tolerate it.
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=90s &>/dev/null \
        || sleep 8
    kubectl logs "$pod" 2>/dev/null | sed 's/^/    /'
    kubectl delete "pod/${pod}" --wait=false &>/dev/null || true
}

raise_maxpods_on_node() {
    local node="$1"
    echo "  ⚙️  ${node}: setting maxPods=${MAX_PODS} ..."
    local inner
    inner=$(cat <<INNEREOF
set -e
CONF="${DROPIN}"
if [ ! -f "\$CONF" ]; then echo "⚠️  drop-in not found (\$CONF) — skipping"; exit 0; fi
CUR=\$(grep -oE '"maxPods": [0-9]+' "\$CONF" | grep -oE '[0-9]+' || echo "")
if [ "\$CUR" = "${MAX_PODS}" ]; then echo "✅ already maxPods=${MAX_PODS} — no change"; exit 0; fi
[ -f "\${CONF}.bak-maxpods" ] || cp -a "\$CONF" "\${CONF}.bak-maxpods"
if grep -qE '"maxPods": [0-9]+' "\$CONF"; then
    sed -i -E 's/"maxPods": [0-9]+/"maxPods": ${MAX_PODS}/' "\$CONF"
else
    echo "⚠️  no maxPods key in drop-in — skipping"; exit 0
fi
echo "maxPods \$CUR -> ${MAX_PODS}; restarting kubelet"
chroot /host systemctl restart kubelet
echo "kubelet restart issued"
INNEREOF
)
    run_on_node "$node" "$inner"
}

revert_maxpods_on_node() {
    local node="$1"
    echo "  ↩️  ${node}: restoring original maxPods ..."
    local inner
    inner=$(cat <<INNEREOF
set -e
CONF="${DROPIN}"
if [ ! -f "\${CONF}.bak-maxpods" ]; then echo "⚠️  no backup found — nothing to revert"; exit 0; fi
cp -a "\${CONF}.bak-maxpods" "\$CONF"
echo "restored from backup; restarting kubelet"
chroot /host systemctl restart kubelet
echo "kubelet restart issued"
INNEREOF
)
    run_on_node "$node" "$inner"
}

print_usage_table() {
    echo "📊 Current node pod usage:"
    for node in $(kubectl get nodes -o name | cut -d/ -f2); do
        local max cur
        max=$(kubectl get node "$node" -o jsonpath='{.status.capacity.pods}' 2>/dev/null)
        cur=$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | grep -v Succeeded | wc -l)
        echo "  $node: ${cur}/${max} pods"
    done
}

verify_maxpods() {
    echo "🔎 Verifying maxPods (kubelet configz):"
    for node in $(kubectl get nodes -o name | cut -d/ -f2); do
        local mp cap
        cap=$(kubectl get node "$node" -o jsonpath='{.status.capacity.pods}' 2>/dev/null)
        mp=$(kubectl get --raw "/api/v1/nodes/${node}/proxy/configz" 2>/dev/null \
            | python3 -c "import sys,json;print(json.load(sys.stdin)['kubeletconfig'].get('maxPods'))" 2>/dev/null || echo "?")
        echo "  $node: capacity.pods=${cap}, configz maxPods=${mp}"
    done
}

NODES=$(kubectl get nodes -o name | cut -d/ -f2)

# ----- Revert mode -----------------------------------------------------------
if $REVERT; then
    echo "↩️  Reverting kubelet maxPods to the original bootstrap value..."
    echo "⚠️  kubelet will restart on each node (brief, pods keep running)."
    confirm "Proceed?" || { echo "Aborted."; exit 0; }
    for node in $NODES; do revert_maxpods_on_node "$node"; done
    sleep 12
    verify_maxpods
    echo "✅ Revert complete."
    exit 0
fi

# ----- Primary: raise maxPods ------------------------------------------------
echo "🔧 Ensuring workshop capacity (target maxPods=${MAX_PODS})"
echo "📊 Before:"
print_usage_table
echo ""
echo "⚠️  This restarts kubelet on each node (brief; running pods are NOT evicted)."
echo "⚠️  This change is reverted automatically if HyperPod reprovisions a node."
confirm "Raise maxPods to ${MAX_PODS} on all nodes?" || { echo "Aborted."; exit 0; }

for node in $NODES; do raise_maxpods_on_node "$node"; done
echo ""
echo "⏳ Waiting for kubelet to re-register..."
sleep 12
verify_maxpods

# ----- Optional: free idle / non-essential pods ------------------------------
if $FREE_IDLE_PODS; then
    echo ""
    echo "🧹 Optional cleanup: freeing idle / non-essential pods"
    echo "   NOTE: components labeled managed-by=EKS may be recreated by the"
    echo "         add-on controller — this is best-effort, not durable."

    echo "📝 Deleting completed (Succeeded) pods..."
    kubectl delete pods --field-selector=status.phase=Succeeded --all-namespaces 2>/dev/null || true

    echo "📝 Scaling down Kueue controller (if present)..."
    kubectl scale deployment -n kueue-system kueue-controller-manager --replicas=0 2>/dev/null || true

    # KEDA actually lives in hyperpod-inference-system (NOT kube-system).
    echo "📝 Scaling down KEDA autoscaling (if present)..."
    kubectl scale deployment -n hyperpod-inference-system keda-operator --replicas=0 2>/dev/null || true
    kubectl scale deployment -n hyperpod-inference-system keda-operator-metrics-apiserver --replicas=0 2>/dev/null || true

    # Real ALB deployment is hyperpod-inference-alb in hyperpod-inference-system.
    echo "📝 Reducing inference ALB to 1 replica (if present)..."
    kubectl scale deployment -n hyperpod-inference-system hyperpod-inference-alb --replicas=1 2>/dev/null || true

    echo ""
    echo "📊 After cleanup:"
    print_usage_table
fi

echo ""
echo "✅ Workshop capacity ensured. Deploy your workload, e.g.:"
echo "   kubectl apply -f deploy_S3_direct.yaml"
