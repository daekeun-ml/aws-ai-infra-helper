ROLE_NAME="AmazonEKSPodIdentityMountpointForAmazonS3CSIDriverRole"

# 1. Pod Identity Agent Add-on 설치
echo "1. Pod Identity Agent 설치..."
aws eks create-addon \
  --cluster-name $EKS_CLUSTER_NAME \
  --addon-name eks-pod-identity-agent \
  --region $AWS_REGION 2>/dev/null || echo "이미 설치됨"

# 2. IAM Role 생성 (Pod Identity Trust Policy)
echo "2. IAM Role 생성..."
cat <<EOF > /tmp/trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file:///tmp/trust-policy.json 2>/dev/null || echo "Role 이미 존재"

ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)
echo "Role ARN: $ROLE_ARN"


# 3. AmazonS3FullAccess 정책 연결
echo "3. AmazonS3FullAccess 정책 연결..."
aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# 4. S3 CSI Driver Add-on 설치
echo "4. S3 CSI Driver Add-on 설치..."
aws eks create-addon \
  --cluster-name $EKS_CLUSTER_NAME \
  --addon-name aws-mountpoint-s3-csi-driver \
  --region $AWS_REGION 2>/dev/null || echo "이미 설치됨"

# 5. Pod Identity Association 생성
echo "5. Pod Identity Association 생성..."
aws eks create-pod-identity-association \
  --cluster-name $EKS_CLUSTER_NAME \
  --namespace kube-system \
  --service-account s3-csi-driver-sa \
  --role-arn ${ROLE_ARN} \
  --region $AWS_REGION 2>/dev/null || echo "Association 이미 존재"

# 6. CSI Driver Pod 재시작
echo "6. CSI Driver Pod 재시작..."
kubectl rollout restart daemonset -n kube-system s3-csi-node