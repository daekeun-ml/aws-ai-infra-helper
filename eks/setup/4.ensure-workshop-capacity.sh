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
#   (default 28). This frees real slots without deleting anything.
#
#   ⚠️ maxPods alone is NOT enough — IP supply must keep up:
#     Raising maxPods only sets the *slot* limit. Each pod also needs an IP
#     from the VPC CNI. Without prefix delegation, ml.g5.2xlarge only gets a
#     handful of secondary IPs (often ~14), so once that many IP-using pods
#     land, new pods fail with "failed to assign an IP address to container"
#     and stay in ContainerCreating — even though maxPods slots remain.
#     So this script ALSO enables VPC CNI prefix delegation by default
#     (ENABLE_PREFIX_DELEGATION=true), which hands out /28 prefixes (16 IPs
#     each) and lifts the per-node IP ceiling to match the higher maxPods.
#     Disable with --no-prefix-delegation.
#
#   OPTIONAL: freeing idle/non-essential pods (the old behavior) is now
#   opt-in via --free-idle-pods, because (a) raising maxPods usually makes it
#   unnecessary, and (b) most of those components are EKS-managed add-ons that
#   the add-on controller recreates, so the effect is only temporary.
#
# How the maxPods change is applied (and why this way):
#   kubelet merges every file under config.json.d (via --config-dir) in lexical
#   order; higher-numbered files win. nodeadm owns 40-nodeadm.conf and may
#   REGENERATE it (resetting maxPods to ~14) on kubelet restart / node boot.
#   So instead of editing 40-nodeadm.conf (which gets overwritten — the classic
#   "maxPods reverts to 14" symptom), this script writes a higher-priority
#   99-workshop-maxpods.conf that overrides maxPods and survives regeneration.
#   The file is a COMPLETE KubeletConfiguration (apiVersion/kind REQUIRED — a
#   partial file makes kubelet fail to start and the node goes NotReady).
#
# IMPORTANT — what persists and what doesn't:
#   - The 99- drop-in survives nodeadm regeneration / kubelet restarts, but it
#     lives on the node's disk, so it is LOST if HyperPod fully reprovisions or
#     health-replaces the node (a brand-new node boots with maxPods ~14).
#     Re-run this script after node replacement. (--revert removes the file.)
#   - prefix delegation is set on the VPC CNI (managed add-on if present, else
#     the aws-node DaemonSet), so it DOES persist across node reprovisioning.
#
# Usage:
#   ./4.ensure-workshop-capacity.sh                    # raise maxPods to 28 + enable prefix delegation
#   ./4.ensure-workshop-capacity.sh --max-pods 40      # custom maxPods target
#   ./4.ensure-workshop-capacity.sh --no-prefix-delegation  # only raise maxPods (skip IP fix)
#   ./4.ensure-workshop-capacity.sh --free-idle-pods   # also run optional cleanup
#   ./4.ensure-workshop-capacity.sh --revert           # restore original maxPods
#   ./4.ensure-workshop-capacity.sh --yes              # no confirmation prompt

set -uo pipefail

MAX_PODS=28
FREE_IDLE_PODS=false
REVERT=false
ASSUME_YES=false
PREFIX_DELEGATION=true
# AL2023 kubelet merges every drop-in under config.json.d (via --config-dir),
# applying them in lexical order — higher-numbered files win. nodeadm owns
# 40-nodeadm.conf and MAY regenerate it (resetting maxPods to e.g. 14) on
# kubelet restart / node boot, so we must NOT edit it. Instead we drop a
# higher-priority 99-* file that overrides maxPods and survives regeneration.
DROPIN_DIR="/host/etc/kubernetes/kubelet/config.json.d"
OURCONF="${DROPIN_DIR}/99-workshop-maxpods.conf"
# Minimal image used by `kubectl debug node` to reach the host filesystem.
DEBUG_IMAGE="public.ecr.aws/amazonlinux/amazonlinux:2023"

usage() { sed -n '3,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-pods) MAX_PODS="$2"; shift 2 ;;
        --no-prefix-delegation) PREFIX_DELEGATION=false; shift ;;
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
    echo "  ⚙️  ${node}: setting maxPods=${MAX_PODS} (via 99- drop-in) ..."
    local inner
    inner=$(cat <<INNEREOF
set -e
CONF="${OURCONF}"
# Already at target? skip (no kubelet restart needed).
if [ -f "\$CONF" ] && grep -q '"maxPods": *${MAX_PODS}\b' "\$CONF"; then
    echo "✅ already maxPods=${MAX_PODS} — no change"; exit 0
fi
# Write a COMPLETE KubeletConfiguration drop-in. The apiVersion/kind are
# REQUIRED — a partial file (e.g. just {"maxPods":N}) makes kubelet fail to
# start and the node goes NotReady. Write atomically (tmp + mv) and validate.
TMP="\${CONF}.tmp"
cat > "\$TMP" <<JSON
{
    "apiVersion": "kubelet.config.k8s.io/v1beta1",
    "kind": "KubeletConfiguration",
    "maxPods": ${MAX_PODS}
}
JSON
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open('\$TMP'))" || { echo "❌ invalid JSON, aborting"; rm -f "\$TMP"; exit 1; }
fi
mv "\$TMP" "\$CONF"
echo "wrote \$CONF (maxPods=${MAX_PODS}); restarting kubelet"
chroot /host systemctl restart kubelet
echo "kubelet restart issued"
INNEREOF
)
    run_on_node "$node" "$inner"
}

revert_maxpods_on_node() {
    local node="$1"
    echo "  ↩️  ${node}: removing workshop maxPods override ..."
    local inner
    inner=$(cat <<INNEREOF
set -e
CONF="${OURCONF}"
if [ ! -f "\$CONF" ]; then echo "✅ no workshop override present — nothing to revert"; exit 0; fi
rm -f "\$CONF"
echo "removed \$CONF; restarting kubelet (reverts to nodeadm default)"
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

# Enable VPC CNI prefix delegation so IP supply matches the higher maxPods.
# Prefer the EKS managed add-on (persists, not reverted by the addon
# controller); fall back to editing the aws-node DaemonSet directly.
enable_prefix_delegation() {
    echo ""
    echo "🌐 Ensuring VPC CNI prefix delegation (so pods get IPs, not just slots)..."

    # Already on? then nothing to do.
    local cur
    cur=$(kubectl get ds aws-node -n kube-system \
        -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
        | grep '^ENABLE_PREFIX_DELEGATION=' | cut -d= -f2)
    if [ "$cur" = "true" ]; then
        echo "  ✅ already enabled (ENABLE_PREFIX_DELEGATION=true)"
        return 0
    fi

    # Is vpc-cni an EKS managed add-on? If so, set it there (durable).
    local via_addon=false
    if command -v aws &>/dev/null; then
        local region cluster
        region="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
        # Derive cluster name from the current kube context (…cluster/<name>).
        cluster=$(kubectl config current-context 2>/dev/null | sed -n 's#.*cluster/##p')
        [ -n "${EKS_CLUSTER_NAME:-}" ] && cluster="$EKS_CLUSTER_NAME"
        if [ -n "$cluster" ] && [ -n "$region" ] \
           && aws eks describe-addon --cluster-name "$cluster" --addon-name vpc-cni \
                --region "$region" &>/dev/null; then
            echo "  → vpc-cni is a managed add-on; updating it (durable)..."
            if aws eks update-addon --cluster-name "$cluster" --addon-name vpc-cni \
                 --resolve-conflicts OVERWRITE \
                 --configuration-values '{"env":{"ENABLE_PREFIX_DELEGATION":"true","WARM_PREFIX_TARGET":"1"}}' \
                 --region "$region" &>/dev/null; then
                # wait until ACTIVE
                local i st
                for i in $(seq 1 18); do
                    st=$(aws eks describe-addon --cluster-name "$cluster" --addon-name vpc-cni \
                         --region "$region" --query 'addon.status' --output text 2>/dev/null)
                    [ "$st" = "ACTIVE" ] && break
                    sleep 10
                done
                via_addon=true
                echo "  ✅ managed add-on updated (status: ${st:-unknown})"
            else
                echo "  ⚠️  update-addon failed; falling back to DaemonSet edit"
            fi
        fi
    fi

    # Fallback: edit the aws-node DaemonSet directly.
    if ! $via_addon; then
        echo "  → setting env on the aws-node DaemonSet..."
        kubectl set env ds aws-node -n kube-system \
            ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1 >/dev/null 2>&1 \
            && echo "  ✅ aws-node updated" \
            || { echo "  ❌ failed to set prefix delegation on aws-node"; return 1; }
    fi

    echo "  ⏳ Rolling out aws-node (brief)..."
    kubectl rollout restart ds/aws-node -n kube-system >/dev/null 2>&1 || true
    kubectl rollout status  ds/aws-node -n kube-system --timeout=180s 2>&1 | tail -1
    echo "  ℹ️  Existing pods already short on IPs may need a restart to pick up new prefixes."
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

# ----- Match IP supply to the higher maxPods (prefix delegation) -------------
if $PREFIX_DELEGATION; then
    enable_prefix_delegation
else
    echo ""
    echo "⏭️  Skipping prefix delegation (--no-prefix-delegation)."
    echo "   ⚠️  Without it, pods may fail with 'failed to assign an IP address'"
    echo "      once IP-using pods exceed the node's secondary-IP budget."
fi

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
