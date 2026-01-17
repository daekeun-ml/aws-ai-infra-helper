#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# Load existing env_vars if available
if [ -f env_vars ]; then
    source env_vars
    echo "[INFO] Loaded existing environment variables"
fi

# SPDX-License-Identifier: MIT-0

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
        # If only one cluster, use it automatically
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

# Find EKS cluster name that contains the HyperPod cluster name
export EKS_CLUSTER_NAME=$(aws eks list-clusters --region ${AWS_REGION} \
    --query "clusters[?contains(@, '${HYPERPOD_CLUSTER_NAME}')]" \
    --output text 2>/dev/null | head -1)

if [[ -z "${EKS_CLUSTER_NAME}" || "${EKS_CLUSTER_NAME}" == "None" ]]; then
    echo "[ERROR] Could not find EKS cluster for HyperPod cluster ${HYPERPOD_CLUSTER_NAME}"
    exit 1
fi

echo "export EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}" >> env_vars
echo "[INFO] EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"

# Find CloudFormation stack using EKS cluster name prefix
STACK_PREFIX=$(echo ${EKS_CLUSTER_NAME} | sed 's/-eks$//')
# First try to find the exact match (main stack)
export STACK_ID=$(aws cloudformation describe-stacks --stack-name "${STACK_PREFIX}" --region ${AWS_REGION} \
    --query 'Stacks[0].StackName' --output text 2>/dev/null)

# If exact match not found, search for stacks with the prefix
if [[ -z "${STACK_ID}" || "${STACK_ID}" == "None" ]]; then
    export STACK_ID=$(aws cloudformation list-stacks --region ${AWS_REGION} \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?starts_with(StackName, '${STACK_PREFIX}') && !contains(StackName, 'Stack')].StackName | [0]" \
        --output text 2>/dev/null)
fi

if [[ -z "${STACK_ID}" || "${STACK_ID}" == "None" ]]; then
    echo "[ERROR] Could not find CloudFormation stack for ${EKS_CLUSTER_NAME}"
    exit 1
fi

echo "export STACK_ID=${STACK_ID}" >> env_vars
echo "[INFO] STACK_ID = ${STACK_ID}"

# Get other resources from CloudFormation stack
export EKS_CLUSTER_ARN=$(aws cloudformation describe-stacks \
    --stack-name $STACK_ID \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputEKSClusterArn`].OutputValue' \
    --region ${AWS_REGION} \
    --output text)
echo "export EKS_CLUSTER_ARN=${EKS_CLUSTER_ARN}" >> env_vars
echo "[INFO] EKS_CLUSTER_ARN = ${EKS_CLUSTER_ARN}"

export S3_BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name $STACK_ID \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputS3BucketName`].OutputValue' \
    --region ${AWS_REGION} \
    --output text)
echo "export S3_BUCKET_NAME=${S3_BUCKET_NAME}" >> env_vars
echo "[INFO] S3_BUCKET_NAME = ${S3_BUCKET_NAME}"

export EXECUTION_ROLE=$(aws cloudformation describe-stacks \
    --stack-name $STACK_ID \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputSageMakerIAMRoleArn`].OutputValue' \
    --region ${AWS_REGION} \
    --output text)
echo "export EXECUTION_ROLE=${EXECUTION_ROLE}" >> env_vars
echo "[INFO] EXECUTION_ROLE = ${EXECUTION_ROLE}"

export VPC_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_ID \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputVpcId`].OutputValue' \
    --region ${AWS_REGION} \
    --output text)
echo "export VPC_ID=${VPC_ID}" >> env_vars
echo "[INFO] VPC_ID = ${VPC_ID}"

export PRIVATE_SUBNET_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_ID \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputPrivateSubnetIds`].OutputValue' \
    --region ${AWS_REGION} \
    --output text)
echo "export PRIVATE_SUBNET_ID=${PRIVATE_SUBNET_ID}" >> env_vars
echo "[INFO] PRIVATE_SUBNET_ID = ${PRIVATE_SUBNET_ID}"

export SECURITY_GROUP_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_ID \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputSecurityGroupId`].OutputValue' \
    --region ${AWS_REGION} \
    --output text)
echo "export SECURITY_GROUP_ID=${SECURITY_GROUP_ID}" >> env_vars
echo "[INFO] SECURITY_GROUP_ID = ${SECURITY_GROUP_ID}"

echo "export HYPERPOD_CLUSTER_NAME=${HYPERPOD_CLUSTER_NAME}" >> env_vars
echo "[INFO] All environment variables saved to env_vars"
