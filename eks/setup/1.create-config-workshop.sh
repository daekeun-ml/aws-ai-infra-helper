#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Workshop version - does not rely on CloudFormation stack

# Install the latest AWS CLI v2 (older builds lack the HyperPod
# Orchestrator.Eks field). See ensure-awscli.sh for details.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-awscli.sh"
ensure_awscli || { echo "[ERROR] AWS CLI setup failed"; exit 1; }

# Load existing env_vars if available
if [ -f env_vars ]; then
    source env_vars
    echo "[INFO] Loaded existing environment variables"
fi

# Clear previously set env_vars 
> env_vars 

# Define AWS Region
if [ -z ${AWS_REGION} ]; then
    echo "[WARNING] AWS_REGION environment variable is not set, automatically set depending on aws cli default region."
    export AWS_REGION=$(aws configure get region)
fi
echo "export AWS_REGION=${AWS_REGION}" >> env_vars
echo "[INFO] AWS_REGION = ${AWS_REGION}"

# Verify AWS credentials BEFORE making any API calls. Otherwise an expired or
# invalid token makes later calls (e.g. list-clusters) fail silently and the
# script misreports it as "No HyperPod clusters found".
echo "[INFO] Verifying AWS credentials..."
CALLER_IDENTITY=$(aws sts get-caller-identity --region ${AWS_REGION} --output text 2>&1)
if [ $? -ne 0 ]; then
    echo "[ERROR] AWS credentials are missing, expired, or invalid."
    echo "[ERROR] Details: ${CALLER_IDENTITY}"
    echo "[ERROR] Please authenticate first, then re-run this script. For example:"
    echo "          export AWS_ACCESS_KEY_ID=..."
    echo "          export AWS_SECRET_ACCESS_KEY=..."
    echo "          export AWS_SESSION_TOKEN=...   # required for temporary/workshop credentials"
    echo "        or run 'aws configure' / 'aws sso login', then verify with:"
    echo "          aws sts get-caller-identity"
    exit 1
fi
echo "[INFO] Authenticated as: ${CALLER_IDENTITY}"

# Get HyperPod cluster name if not set
if [ -z "${HYPERPOD_CLUSTER_NAME}" ]; then
    echo "[INFO] HYPERPOD_CLUSTER_NAME not set, searching for HyperPod clusters..."
    CLUSTERS=$(aws sagemaker list-clusters --region ${AWS_REGION} --query 'ClusterSummaries[?ClusterStatus==`InService`].ClusterName' --output text)
    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to list HyperPod clusters (see error above)."
        exit 1
    fi

    if [[ ! -z "${CLUSTERS}" && "${CLUSTERS}" != "None" ]]; then
        echo "[INFO] Found HyperPod clusters: ${CLUSTERS}"
        echo "[INFO] Please select a HyperPod cluster:"
        select cluster in ${CLUSTERS}; do
            if [[ -n "$cluster" ]]; then
                export HYPERPOD_CLUSTER_NAME="$cluster"
                echo "[INFO] Selected HYPERPOD_CLUSTER_NAME = ${HYPERPOD_CLUSTER_NAME}"
                break
            else
                echo "Invalid selection. Please try again."
            fi
        done
    else
        echo "[ERROR] No HyperPod clusters found"
        exit 1
    fi
fi
echo "export HYPERPOD_CLUSTER_NAME=${HYPERPOD_CLUSTER_NAME}" >> env_vars

# Get EKS cluster name from HyperPod cluster
export EKS_CLUSTER_NAME=$(aws sagemaker describe-cluster --cluster-name ${HYPERPOD_CLUSTER_NAME} --region ${AWS_REGION} --query 'Orchestrator.Eks.ClusterArn' --output text 2>/dev/null | cut -d'/' -f2)

if [[ -z "${EKS_CLUSTER_NAME}" || "${EKS_CLUSTER_NAME}" == "None" ]]; then
    echo "[ERROR] Could not find EKS cluster for HyperPod cluster ${HYPERPOD_CLUSTER_NAME}"
    exit 1
fi

echo "export EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}" >> env_vars
echo "[INFO] EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"

# Get EKS cluster ARN
export EKS_CLUSTER_ARN=$(aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.arn' --output text)
echo "export EKS_CLUSTER_ARN=${EKS_CLUSTER_ARN}" >> env_vars
echo "[INFO] EKS_CLUSTER_ARN = ${EKS_CLUSTER_ARN}"

# Get VPC ID from EKS cluster
export VPC_ID=$(aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "export VPC_ID=${VPC_ID}" >> env_vars
echo "[INFO] VPC_ID = ${VPC_ID}"

# Get private subnets from EKS cluster
export PRIVATE_SUBNET_ID=$(aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',')
echo "export PRIVATE_SUBNET_ID=${PRIVATE_SUBNET_ID}" >> env_vars
echo "[INFO] PRIVATE_SUBNET_ID = ${PRIVATE_SUBNET_ID}"

# Get security group from EKS cluster
export SECURITY_GROUP_ID=$(aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
echo "export SECURITY_GROUP_ID=${SECURITY_GROUP_ID}" >> env_vars
echo "[INFO] SECURITY_GROUP_ID = ${SECURITY_GROUP_ID}"

# Find S3 buckets with 'sagemaker' in the name
S3_BUCKETS=$(aws s3 ls | grep "sagemaker" | awk '{print $3}')

if [[ -z "${S3_BUCKETS}" ]]; then
    echo "[WARNING] No S3 buckets found with 'sagemaker' in the name"
else
    echo "[INFO] Available SageMaker S3 buckets. Please select one:"
    PS3="Select bucket number: "
    select bucket in ${S3_BUCKETS}; do
        if [[ -n "$bucket" ]]; then
            export S3_BUCKET_NAME="$bucket"
            echo "[INFO] Selected S3_BUCKET_NAME = ${S3_BUCKET_NAME}"
            echo "export S3_BUCKET_NAME=${S3_BUCKET_NAME}" >> env_vars
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
fi

# Find SageMaker execution role
export EXECUTION_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, 'SageMaker') && contains(RoleName, 'Execution')].Arn | [0]" --output text)
if [[ -z "${EXECUTION_ROLE}" || "${EXECUTION_ROLE}" == "None" ]]; then
    echo "[WARNING] Could not find SageMaker execution role"
else
    echo "export EXECUTION_ROLE=${EXECUTION_ROLE}" >> env_vars
    echo "[INFO] EXECUTION_ROLE = ${EXECUTION_ROLE}"
fi

echo "[INFO] All environment variables saved to env_vars"
