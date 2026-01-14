#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Workshop version - does not rely on CloudFormation stack

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

# Get HyperPod cluster name if not set
if [ -z "${HYPERPOD_CLUSTER_NAME}" ]; then
    echo "[INFO] HYPERPOD_CLUSTER_NAME not set, searching for HyperPod clusters..."
    CLUSTERS=$(aws sagemaker list-clusters --region ${AWS_REGION} --query 'ClusterSummaries[?ClusterStatus==`InService`].ClusterName' --output text 2>/dev/null)
    
    if [[ ! -z "${CLUSTERS}" && "${CLUSTERS}" != "None" ]]; then
        echo "[INFO] Found HyperPod clusters: ${CLUSTERS}"
        CLUSTER_COUNT=$(echo ${CLUSTERS} | wc -w)
        if [ ${CLUSTER_COUNT} -eq 1 ]; then
            export HYPERPOD_CLUSTER_NAME="${CLUSTERS}"
            echo "[INFO] Auto-selected HYPERPOD_CLUSTER_NAME = ${HYPERPOD_CLUSTER_NAME}"
        else
            echo "[INFO] Multiple clusters found, please select:"
            select cluster in ${CLUSTERS}; do
                if [[ -n "$cluster" ]]; then
                    export HYPERPOD_CLUSTER_NAME="$cluster"
                    echo "[INFO] Selected HYPERPOD_CLUSTER_NAME = ${HYPERPOD_CLUSTER_NAME}"
                    break
                else
                    echo "Invalid selection. Please try again."
                fi
            done
        fi
    else
        echo "[ERROR] No HyperPod clusters found"
        exit 1
    fi
fi
echo "export HYPERPOD_CLUSTER_NAME=${HYPERPOD_CLUSTER_NAME}" >> env_vars

# Get all EKS clusters
EKS_CLUSTERS=$(aws eks list-clusters --region ${AWS_REGION} --query 'clusters' --output text 2>/dev/null)

if [[ -z "${EKS_CLUSTERS}" || "${EKS_CLUSTERS}" == "None" ]]; then
    echo "[ERROR] No EKS clusters found in region ${AWS_REGION}"
    exit 1
fi

# Try to auto-match first
export EKS_CLUSTER_NAME=$(echo ${EKS_CLUSTERS} | tr '\t' '\n' | grep -i "${HYPERPOD_CLUSTER_NAME}" | head -1)

if [[ -z "${EKS_CLUSTER_NAME}" ]]; then
    echo "[INFO] Could not auto-match EKS cluster. Available EKS clusters:"
    select cluster in ${EKS_CLUSTERS}; do
        if [[ -n "$cluster" ]]; then
            export EKS_CLUSTER_NAME="$cluster"
            echo "[INFO] Selected EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
else
    echo "[INFO] Auto-matched EKS cluster"
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

# Find S3 buckets starting with sagemaker-hyperpod-eks-bucket-
S3_BUCKETS=$(aws s3 ls | grep "sagemaker-hyperpod-eks-bucket-" | awk '{print $3}')

if [[ -z "${S3_BUCKETS}" ]]; then
    echo "[WARNING] No S3 buckets found starting with 'sagemaker-hyperpod-eks-bucket-'"
else
    BUCKET_COUNT=$(echo "${S3_BUCKETS}" | wc -l)
    if [ ${BUCKET_COUNT} -eq 1 ]; then
        export S3_BUCKET_NAME="${S3_BUCKETS}"
        echo "[INFO] Auto-selected S3_BUCKET_NAME = ${S3_BUCKET_NAME}"
    else
        echo "[INFO] Multiple S3 buckets found. Select one (press Enter for default):"
        PS3="Select bucket number: "
        select bucket in ${S3_BUCKETS}; do
            if [[ -n "$bucket" ]]; then
                export S3_BUCKET_NAME="$bucket"
                echo "[INFO] Selected S3_BUCKET_NAME = ${S3_BUCKET_NAME}"
                break
            elif [[ -z "$REPLY" ]]; then
                export S3_BUCKET_NAME=$(echo "${S3_BUCKETS}" | head -1)
                echo "[INFO] Using default S3_BUCKET_NAME = ${S3_BUCKET_NAME}"
                break
            else
                echo "Invalid selection. Try again or press Enter for default."
            fi
        done
    fi
    echo "export S3_BUCKET_NAME=${S3_BUCKET_NAME}" >> env_vars
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
