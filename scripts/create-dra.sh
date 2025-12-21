#!/bin/bash

set -e

# AWS 계정 ID 가져오기
# Get AWS Account ID with fallback
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" = "None" ]; then
    AWS_ACCOUNT_ID="handson$(shuf -i 100000-999999 -n 1)"
    echo "⚠️  Could not retrieve AWS Account ID, using fallback: $AWS_ACCOUNT_ID"
fi
export AWS_ACCOUNT_ID
export AWS_REGION=$(aws configure get region)

# FSX_LUSTRE_ID 체크
if [ -z "$FSX_LUSTRE_ID" ]; then
    echo "Error: FSX_LUSTRE_ID is not set. Please run export-stack-outputs.sh first."
    exit 1
fi

# 버킷 이름 설정
export S3_BUCKET_NAME=hyperpod-${AWS_ACCOUNT_ID}-${AWS_REGION}

# DRA 존재 여부 확인 함수
check_dra_exists() {
    local path=$1
    aws fsx describe-data-repository-associations \
        --filters Name=file-system-id,Values=${FSX_LUSTRE_ID} \
        --query "Associations[?FileSystemPath=='$path'].AssociationId" \
        --output text --region ${AWS_REGION} | grep -q .
}

# 학습 데이터용 DRA
if check_dra_exists "/data"; then
    echo "DRA for /data already exists"
else
    aws fsx create-data-repository-association \
        --file-system-id ${FSX_LUSTRE_ID} \
        --file-system-path /data \
        --data-repository-path s3://${S3_BUCKET_NAME}/data/ \
        --batch-import-meta-data-on-create \
        --s3 '{"AutoImportPolicy":{"Events":["NEW","CHANGED","DELETED"]}}' \
        --region ${AWS_REGION}
fi

# 체크포인트용 DRA
if check_dra_exists "/checkpoints"; then
    echo "DRA for /checkpoints already exists"
else
    aws fsx create-data-repository-association \
        --file-system-id ${FSX_LUSTRE_ID} \
        --file-system-path /checkpoints \
        --data-repository-path s3://${S3_BUCKET_NAME}/checkpoints/ \
        --s3 '{"AutoImportPolicy":{"Events":["NEW","CHANGED","DELETED"]},"AutoExportPolicy":{"Events":["NEW","CHANGED","DELETED"]}}' \
        --region ${AWS_REGION}
fi

# 로그용 DRA
if check_dra_exists "/logs"; then
    echo "DRA for /logs already exists"
else
    aws fsx create-data-repository-association \
        --file-system-id ${FSX_LUSTRE_ID} \
        --file-system-path /logs \
        --data-repository-path s3://${S3_BUCKET_NAME}/logs/ \
        --s3 '{"AutoExportPolicy":{"Events":["NEW","CHANGED","DELETED"]}}' \
        --region ${AWS_REGION}
fi

# 결과용 DRA
if check_dra_exists "/results"; then
    echo "DRA for /results already exists"
else
    aws fsx create-data-repository-association \
        --file-system-id ${FSX_LUSTRE_ID} \
        --file-system-path /results \
        --data-repository-path s3://${S3_BUCKET_NAME}/results/ \
        --s3 '{"AutoExportPolicy":{"Events":["NEW","CHANGED","DELETED"]}}' \
        --region ${AWS_REGION}
fi

# FSx 디렉토리 생성 및 권한 설정
echo "📁 Creating FSx directories and setting permissions..."
sudo mkdir -p /fsx/data /fsx/checkpoints /fsx/logs /fsx/results
sudo chown -R ubuntu:ubuntu /fsx/data /fsx/checkpoints /fsx/logs /fsx/results
sudo chmod -R 755 /fsx/data /fsx/checkpoints /fsx/logs /fsx/results
echo "✅ FSx directories created with ubuntu ownership"
