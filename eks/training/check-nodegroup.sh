#!/bin/bash

set -e

echo "=== EKS Cluster and NodeGroup Information ==="
echo ""

# 클러스터 이름 확인
CLUSTER_NAME=$(aws eks list-clusters --query 'clusters[0]' --output text)
echo "Cluster Name: ${CLUSTER_NAME}"
echo ""

# 노드 그룹 목록
echo "NodeGroups:"
aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} --query 'nodegroups' --output text
echo ""

# 각 노드 그룹 상세 정보
NODEGROUPS=$(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} --query 'nodegroups[]' --output text)

for NODEGROUP in ${NODEGROUPS}; do
    echo "=== NodeGroup: ${NODEGROUP} ==="
    
    # 기본 정보
    aws eks describe-nodegroup \
      --cluster-name ${CLUSTER_NAME} \
      --nodegroup-name ${NODEGROUP} \
      --query '{
        InstanceType: nodegroup.instanceTypes[0],
        DesiredSize: nodegroup.scalingConfig.desiredSize,
        MinSize: nodegroup.scalingConfig.minSize,
        MaxSize: nodegroup.scalingConfig.maxSize,
        LaunchTemplateId: nodegroup.launchTemplate.id,
        LaunchTemplateVersion: nodegroup.launchTemplate.version
      }' --output table
    
    echo ""
done

# 현재 노드별 Pod 수
echo "=== Current Pod Count per Node ==="
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.pods}{"\t"}{.status.allocatable.pods}{"\n"}{end}' | column -t
echo ""

echo "=== Pod Usage per Node ==="
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    pod_count=$(kubectl get pods -A -o wide | grep $node | wc -l)
    echo "$node: $pod_count pods"
done
