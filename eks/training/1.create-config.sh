#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

# Get SageMaker HyperPod clusters and match with EKS clusters
if [ -z ${EKS_CLUSTER_NAME} ]; then
    echo "[INFO] EKS_CLUSTER_NAME not set, searching for matching clusters..."
    
    # Get SageMaker HyperPod clusters
    HYPERPOD_CLUSTERS=$(aws sagemaker list-clusters --region ${AWS_REGION} --query 'ClusterSummaries[].ClusterName' --output text 2>/dev/null)
    
    # Get EKS clusters
    EKS_CLUSTERS=$(aws eks list-clusters --region ${AWS_REGION} --query 'clusters[]' --output text 2>/dev/null)
    
    if [[ -z "${HYPERPOD_CLUSTERS}" ]]; then
        echo "[ERROR] No SageMaker HyperPod clusters found in region ${AWS_REGION}"
        return 1
    fi
    
    if [[ -z "${EKS_CLUSTERS}" ]]; then
        echo "[ERROR] No EKS clusters found in region ${AWS_REGION}"
        return 1
    fi
    
    # Find matching clusters
    MATCHED_CLUSTERS=()
    for hyperpod in ${HYPERPOD_CLUSTERS}; do
        for eks in ${EKS_CLUSTERS}; do
            if [[ "${eks}" == *"${hyperpod}"* ]]; then
                MATCHED_CLUSTERS+=("${eks}:${hyperpod}")
            fi
        done
    done
    
    if [[ ${#MATCHED_CLUSTERS[@]} -eq 0 ]]; then
        echo "[ERROR] No matching EKS clusters found for HyperPod clusters"
        echo "[INFO] HyperPod clusters: ${HYPERPOD_CLUSTERS}"
        echo "[INFO] EKS clusters: ${EKS_CLUSTERS}"
        return 1
    elif [[ ${#MATCHED_CLUSTERS[@]} -eq 1 ]]; then
        # Single match found
        SELECTED_MATCH="${MATCHED_CLUSTERS[0]}"
        export EKS_CLUSTER_NAME="${SELECTED_MATCH%%:*}"
        HYPERPOD_NAME="${SELECTED_MATCH##*:}"
        echo "[INFO] Found matching cluster: EKS=${EKS_CLUSTER_NAME}, HyperPod=${HYPERPOD_NAME}"
    else
        # Multiple matches, let user choose
        echo "[INFO] Multiple matching clusters found:"
        for i in "${!MATCHED_CLUSTERS[@]}"; do
            EKS_NAME="${MATCHED_CLUSTERS[$i]%%:*}"
            HYPERPOD_NAME="${MATCHED_CLUSTERS[$i]##*:}"
            echo "  $((i+1)). EKS: ${EKS_NAME} <-> HyperPod: ${HYPERPOD_NAME}"
        done
        
        while true; do
            read -p "Select cluster (1-${#MATCHED_CLUSTERS[@]}): " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MATCHED_CLUSTERS[@]}" ]; then
                SELECTED_MATCH="${MATCHED_CLUSTERS[$((choice-1))]}"
                export EKS_CLUSTER_NAME="${SELECTED_MATCH%%:*}"
                HYPERPOD_NAME="${SELECTED_MATCH##*:}"
                echo "[INFO] Selected: EKS=${EKS_CLUSTER_NAME}, HyperPod=${HYPERPOD_NAME}"
                break
            else
                echo "[ERROR] Invalid selection. Please enter a number between 1 and ${#MATCHED_CLUSTERS[@]}"
            fi
        done
    fi
    
    echo "export EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}" >> env_vars
    echo "[INFO] EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"
else
    echo "[INFO] Using existing EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"
fi

# Try to find STACK_ID from EKS cluster tags
if [ -z ${STACK_ID} ]; then
    echo "[INFO] STACK_ID not set, searching from EKS cluster tags..."
    STACK_FROM_TAGS=$(aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION} \
        --query 'cluster.tags."aws:cloudformation:stack-name"' --output text 2>/dev/null)
    
    if [[ ! -z "${STACK_FROM_TAGS}" && "${STACK_FROM_TAGS}" != "None" ]]; then
        # Extract main stack name from nested stack name
        MAIN_STACK_NAME=$(echo "${STACK_FROM_TAGS}" | sed 's/-[^-]*Stack-[^-]*$//')
        export STACK_ID=${MAIN_STACK_NAME}
        echo "export STACK_ID=${STACK_ID}" >> env_vars
        echo "[INFO] Found main STACK_ID from EKS tags: ${STACK_ID}"
    else
        echo "[WARNING] Could not find STACK_ID from EKS cluster tags"
        echo "[INFO] Searching for CloudFormation stack..."
        FOUND_STACK=$(aws cloudformation describe-stacks --region ${AWS_REGION} \
            --query "Stacks[?starts_with(StackName, 'sagemaker-hyperpod-cluster-eks-') && Description=='Main Stack for EKS based HyperPod Cluster'].StackName | [0]" \
            --output text 2>/dev/null)
        
        if [[ ! -z "${FOUND_STACK}" && "${FOUND_STACK}" != "None" ]]; then
            export STACK_ID=${FOUND_STACK}
            echo "export STACK_ID=${STACK_ID}" >> env_vars
            echo "[INFO] Found stack: ${STACK_ID}"
        else
            echo "[WARNING] No CloudFormation stack found, continuing without STACK_ID"
        fi
    fi
else
    echo "[INFO] Using existing STACK_ID = ${STACK_ID}"
    echo "export STACK_ID=${STACK_ID}" >> env_vars
fi

# Retrieve EKS CLUSTER ARN
if [[ -z "${EKS_CLUSTER_ARN}" ]]; then
    if [[ ! -z "${STACK_ID}" ]]; then
        export EKS_CLUSTER_ARN=`aws cloudformation describe-stacks \
            --stack-name $STACK_ID \
            --query 'Stacks[0].Outputs[?OutputKey==\`OutputEKSClusterArn\`].OutputValue' \
            --region ${AWS_REGION} \
            --output text`
    fi

    if [[ -z "${EKS_CLUSTER_ARN}" && ! -z "${EKS_CLUSTER_NAME}" ]]; then
        if aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION} &>/dev/null; then
            export EKS_CLUSTER_ARN=`aws eks describe-cluster \
                --name ${EKS_CLUSTER_NAME} \
                --query 'cluster.arn' \
                --region ${AWS_REGION} \
                --output text`
            echo "[INFO] Retrieved EKS_CLUSTER_ARN from existing cluster"
        else
            echo "[ERROR] EKS cluster ${EKS_CLUSTER_NAME} does not exist in region ${AWS_REGION}"
            return 1
        fi
    fi

    if [[ ! -z "${EKS_CLUSTER_ARN}" ]]; then
        echo "export EKS_CLUSTER_ARN=${EKS_CLUSTER_ARN}" >> env_vars
        echo "[INFO] EKS_CLUSTER_ARN = ${EKS_CLUSTER_ARN}"
    else
        echo "[ERROR] failed to retrieve EKS_CLUSTER_ARN"
        return 1
    fi
else
    echo "[INFO] Using existing EKS_CLUSTER_ARN = ${EKS_CLUSTER_ARN}"
fi

# Check if S3_BUCKET_NAME is already set and not empty
if [[ -z "${S3_BUCKET_NAME}" && ! -z "${STACK_ID}" ]]; then
    export S3_BUCKET_NAME=`aws cloudformation describe-stacks \
        --stack-name $STACK_ID \
        --query 'Stacks[0].Outputs[?OutputKey==\`OutputS3BucketName\`].OutputValue' \
        --region ${AWS_REGION} \
        --output text`

    if [[ ! -z $S3_BUCKET_NAME ]]; then
        echo "export S3_BUCKET_NAME=${S3_BUCKET_NAME}" >> env_vars
        echo "[INFO] S3_BUCKET_NAME = ${S3_BUCKET_NAME}"
    else
        echo "[WARNING] failed to retrieve S3_BUCKET_NAME from CloudFormation"
    fi
elif [[ ! -z "${S3_BUCKET_NAME}" ]]; then
    echo "[INFO] Using existing S3_BUCKET_NAME = ${S3_BUCKET_NAME}"
    echo "export S3_BUCKET_NAME=${S3_BUCKET_NAME}" >> env_vars
fi

# Check if EXECUTION_ROLE is already set and not empty
if [[ -z "${EXECUTION_ROLE}" && ! -z "${STACK_ID}" ]]; then
    export EXECUTION_ROLE=`aws cloudformation describe-stacks \
        --stack-name $STACK_ID \
        --query 'Stacks[0].Outputs[?OutputKey==\`OutputSageMakerIAMRoleArn\`].OutputValue' \
        --region ${AWS_REGION} \
        --output text`

    if [[ ! -z $EXECUTION_ROLE ]]; then
        echo "export EXECUTION_ROLE=${EXECUTION_ROLE}" >> env_vars
        echo "[INFO] EXECUTION_ROLE = ${EXECUTION_ROLE}"
    else
        echo "[WARNING] failed to retrieve EXECUTION_ROLE from CloudFormation"
    fi
elif [[ ! -z "${EXECUTION_ROLE}" ]]; then
    echo "[INFO] Using existing EXECUTION_ROLE = ${EXECUTION_ROLE}"
    echo "export EXECUTION_ROLE=${EXECUTION_ROLE}" >> env_vars
fi

# Check if VPC_ID is already set and not empty
if [[ -z "${VPC_ID}" && ! -z "${STACK_ID}" ]]; then
    export VPC_ID=`aws cloudformation describe-stacks \
        --stack-name $STACK_ID \
        --query 'Stacks[0].Outputs[?OutputKey==\`OutputVpcId\`].OutputValue' \
        --region ${AWS_REGION} \
        --output text`

    if [[ ! -z $VPC_ID ]]; then
        echo "export VPC_ID=${VPC_ID}" >> env_vars
        echo "[INFO] VPC_ID = ${VPC_ID}"
    else
        echo "[WARNING] failed to retrieve VPC_ID from CloudFormation"
    fi
elif [[ ! -z "${VPC_ID}" ]]; then
    echo "[INFO] Using existing VPC_ID = ${VPC_ID}"
    echo "export VPC_ID=${VPC_ID}" >> env_vars
fi

# Check if PRIVATE_SUBNET_ID is already set and not empty
if [[ -z "${PRIVATE_SUBNET_ID}" && ! -z "${STACK_ID}" ]]; then
    export PRIVATE_SUBNET_ID=`aws cloudformation describe-stacks \
        --stack-name $STACK_ID \
        --query 'Stacks[0].Outputs[?OutputKey==\`OutputPrivateSubnetIds\`].OutputValue' \
        --region ${AWS_REGION} \
        --output text`

    if [[ ! -z $PRIVATE_SUBNET_ID ]]; then
        echo "export PRIVATE_SUBNET_ID=${PRIVATE_SUBNET_ID}" >> env_vars
        echo "[INFO] PRIVATE_SUBNET_ID = ${PRIVATE_SUBNET_ID}"
    else
        echo "[WARNING] failed to retrieve PRIVATE_SUBNET_ID from CloudFormation"
    fi
elif [[ ! -z "${PRIVATE_SUBNET_ID}" ]]; then
    echo "[INFO] Using existing PRIVATE_SUBNET_ID = ${PRIVATE_SUBNET_ID}"
    echo "export PRIVATE_SUBNET_ID=${PRIVATE_SUBNET_ID}" >> env_vars
fi

# Check if SECURITY_GROUP_ID is already set and not empty
if [[ -z "${SECURITY_GROUP_ID}" && ! -z "${STACK_ID}" ]]; then
    export SECURITY_GROUP_ID=`aws cloudformation describe-stacks \
        --stack-name $STACK_ID \
        --query 'Stacks[0].Outputs[?OutputKey==\`OutputSecurityGroupId\`].OutputValue' \
        --region ${AWS_REGION} \
        --output text`

    if [[ ! -z $SECURITY_GROUP_ID ]]; then
        echo "export SECURITY_GROUP_ID=${SECURITY_GROUP_ID}" >> env_vars
        echo "[INFO] SECURITY_GROUP_ID = ${SECURITY_GROUP_ID}"
    else
        echo "[WARNING] failed to retrieve SECURITY_GROUP_ID from CloudFormation"
    fi
elif [[ ! -z "${SECURITY_GROUP_ID}" ]]; then
    echo "[INFO] Using existing SECURITY_GROUP_ID = ${SECURITY_GROUP_ID}"
    echo "export SECURITY_GROUP_ID=${SECURITY_GROUP_ID}" >> env_vars
fi

# Retrieve HyperPod cluster information
if [[ ! -z "${HYPERPOD_NAME}" ]]; then
    CLUSTER_NAME="${HYPERPOD_NAME}"
else
    CLUSTER_NAME=$(aws sagemaker list-clusters --region ${AWS_REGION} --query 'ClusterSummaries[0].ClusterName' --output text 2>/dev/null | head -1)
fi

if [[ ! -z "${CLUSTER_NAME}" && "${CLUSTER_NAME}" != "None" ]]; then
    echo "[INFO] Using HyperPod cluster: ${CLUSTER_NAME}"
    
    # Get instance groups from cluster
    INSTANCE_GROUPS=$(aws sagemaker describe-cluster --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'InstanceGroups' --output json 2>/dev/null)
    
    if [[ ! -z "${INSTANCE_GROUPS}" ]]; then
        # Parse accelerator instances (GPU instances)
        ACCEL_COUNT=0
        while IFS= read -r line; do
            INSTANCE_TYPE=$(echo "$line" | jq -r '.InstanceType')
            
            # Check if it's an accelerator instance
            if [[ "$INSTANCE_TYPE" == ml.g* ]] || [[ "$INSTANCE_TYPE" == ml.p* ]] || [[ "$INSTANCE_TYPE" == ml.trn* ]]; then
                ACCEL_COUNT=$((ACCEL_COUNT + 1))
                INSTANCE_COUNT=$(echo "$line" | jq -r '.TargetCount')
                VOLUME_SIZE=$(echo "$line" | jq -r '.InstanceStorageConfigs[0].EbsVolumeConfig.VolumeSizeInGB // 500')
                
                if [ $ACCEL_COUNT -eq 1 ]; then
                    export ACCEL_INSTANCE_TYPE=${INSTANCE_TYPE}
                    export ACCEL_INSTANCE_COUNT=${INSTANCE_COUNT}
                    export ACCEL_VOLUME_SIZE=${VOLUME_SIZE}
                    echo "export ACCEL_INSTANCE_TYPE=${ACCEL_INSTANCE_TYPE}" >> env_vars
                    echo "export ACCEL_INSTANCE_COUNT=${ACCEL_INSTANCE_COUNT}" >> env_vars
                    echo "export ACCEL_VOLUME_SIZE=${ACCEL_VOLUME_SIZE}" >> env_vars
                    echo "[INFO] ACCEL_INSTANCE_TYPE = ${ACCEL_INSTANCE_TYPE}"
                    echo "[INFO] ACCEL_INSTANCE_COUNT = ${ACCEL_INSTANCE_COUNT}"
                    echo "[INFO] ACCEL_VOLUME_SIZE = ${ACCEL_VOLUME_SIZE}"
                else
                    VAR_NAME="ACCEL${ACCEL_COUNT}_INSTANCE_TYPE"
                    VAR_COUNT="ACCEL${ACCEL_COUNT}_INSTANCE_COUNT"
                    VAR_SIZE="ACCEL${ACCEL_COUNT}_VOLUME_SIZE"
                    declare ${VAR_NAME}=${INSTANCE_TYPE}
                    declare ${VAR_COUNT}=${INSTANCE_COUNT}
                    declare ${VAR_SIZE}=${VOLUME_SIZE}
                    echo "export ${VAR_NAME}=${INSTANCE_TYPE}" >> env_vars
                    echo "export ${VAR_COUNT}=${INSTANCE_COUNT}" >> env_vars
                    echo "export ${VAR_SIZE}=${VOLUME_SIZE}" >> env_vars
                    echo "[INFO] ${VAR_NAME} = ${INSTANCE_TYPE}"
                    echo "[INFO] ${VAR_COUNT} = ${INSTANCE_COUNT}"
                    echo "[INFO] ${VAR_SIZE} = ${VOLUME_SIZE}"
                fi
            fi
        done < <(echo "${INSTANCE_GROUPS}" | jq -c '.[]')
        
        # Parse general purpose instances (CPU instances)
        GEN_COUNT=0
        while IFS= read -r line; do
            INSTANCE_TYPE=$(echo "$line" | jq -r '.InstanceType')
            
            # Check if it's a general purpose instance
            if [[ "$INSTANCE_TYPE" == ml.m* ]] || [[ "$INSTANCE_TYPE" == ml.c* ]] || [[ "$INSTANCE_TYPE" == ml.r* ]]; then
                GEN_COUNT=$((GEN_COUNT + 1))
                INSTANCE_COUNT=$(echo "$line" | jq -r '.TargetCount')
                VOLUME_SIZE=$(echo "$line" | jq -r '.InstanceStorageConfigs[0].EbsVolumeConfig.VolumeSizeInGB // 500')
                
                if [ $GEN_COUNT -eq 1 ]; then
                    export GEN_INSTANCE_TYPE=${INSTANCE_TYPE}
                    export GEN_INSTANCE_COUNT=${INSTANCE_COUNT}
                    export GEN_VOLUME_SIZE=${VOLUME_SIZE}
                    echo "export GEN_INSTANCE_TYPE=${GEN_INSTANCE_TYPE}" >> env_vars
                    echo "export GEN_INSTANCE_COUNT=${GEN_INSTANCE_COUNT}" >> env_vars
                    echo "export GEN_VOLUME_SIZE=${GEN_VOLUME_SIZE}" >> env_vars
                    echo "[INFO] GEN_INSTANCE_TYPE = ${GEN_INSTANCE_TYPE}"
                    echo "[INFO] GEN_INSTANCE_COUNT = ${GEN_INSTANCE_COUNT}"
                    echo "[INFO] GEN_VOLUME_SIZE = ${GEN_VOLUME_SIZE}"
                fi
            fi
        done < <(echo "${INSTANCE_GROUPS}" | jq -c '.[]')
    fi
fi

# Fallback to defaults if not retrieved from cluster
if [ -z ${ACCEL_INSTANCE_TYPE} ]; then
    echo "[WARNING] ACCEL_INSTANCE_TYPE not found in cluster, automatically set to ml.g5.12xlarge."
    export ACCEL_INSTANCE_TYPE=ml.g5.12xlarge
    echo "export ACCEL_INSTANCE_TYPE=${ACCEL_INSTANCE_TYPE}" >> env_vars
    echo "[INFO] ACCEL_INSTANCE_TYPE = ${ACCEL_INSTANCE_TYPE}"
fi

if [ -z ${ACCEL_INSTANCE_COUNT} ]; then
    echo "[WARNING] ACCEL_INSTANCE_COUNT not found in cluster, automatically set to 1."
    export ACCEL_INSTANCE_COUNT=1
    echo "export ACCEL_INSTANCE_COUNT=${ACCEL_INSTANCE_COUNT}" >> env_vars
    echo "[INFO] ACCEL_INSTANCE_COUNT = ${ACCEL_INSTANCE_COUNT}"
fi

if [ -z ${ACCEL_VOLUME_SIZE} ]; then
    echo "[WARNING] ACCEL_VOLUME_SIZE not found in cluster, automatically set to 500."
    export ACCEL_VOLUME_SIZE=500
    echo "export ACCEL_VOLUME_SIZE=${ACCEL_VOLUME_SIZE}" >> env_vars
    echo "[INFO] ACCEL_VOLUME_SIZE = ${ACCEL_VOLUME_SIZE}"
fi

if [ -z ${GEN_INSTANCE_TYPE} ]; then
    echo "[WARNING] GEN_INSTANCE_TYPE not found in cluster, automatically set to ml.m5.2xlarge."
    export GEN_INSTANCE_TYPE=ml.m5.2xlarge
    echo "export GEN_INSTANCE_TYPE=${GEN_INSTANCE_TYPE}" >> env_vars
    echo "[INFO] GEN_INSTANCE_TYPE = ${GEN_INSTANCE_TYPE}"
fi

if [ -z ${GEN_INSTANCE_COUNT} ]; then
    echo "[WARNING] GEN_INSTANCE_COUNT not found in cluster, automatically set to 1."
    export GEN_INSTANCE_COUNT=1
    echo "export GEN_INSTANCE_COUNT=${GEN_INSTANCE_COUNT}" >> env_vars
    echo "[INFO] GEN_INSTANCE_COUNT = ${GEN_INSTANCE_COUNT}"
fi

if [ -z ${GEN_VOLUME_SIZE} ]; then
    echo "[WARNING] GEN_VOLUME_SIZE not found in cluster, automatically set to 500."
    export GEN_VOLUME_SIZE=500
    echo "export GEN_VOLUME_SIZE=${GEN_VOLUME_SIZE}" >> env_vars
    echo "[INFO] GEN_VOLUME_SIZE = ${GEN_VOLUME_SIZE}"
fi

# Set auto-recovery
if [ -z ${NODE_RECOVERY} ]; then
    echo "[WARNING] NODE_RECOVERY environment variable is not set, set to Automatic."
    export NODE_RECOVERY="Automatic"
fi
echo "export NODE_RECOVERY=${NODE_RECOVERY}" >> env_vars
echo "[INFO] NODE_RECOVERY = ${NODE_RECOVERY}"

# Set network flag for Docker if in SageMaker Code Editor
if [ "${SAGEMAKER_APP_TYPE:-}" = "CodeEditor" ]; then 
    echo "export DOCKER_NETWORK=\"--network sagemaker\"" >> env_vars
fi 

# Get absolute path of env_vars file
ENV_VARS_PATH="$(realpath "$(dirname "$0")/env_vars")"

# Persist the environment variables
add_source_command() {
    local config_file="$1"
    local source_line="[ -f \"${ENV_VARS_PATH}\" ] && source \"${ENV_VARS_PATH}\""
    
    if ! grep -q "source.*${ENV_VARS_PATH}" "$config_file"; then
        echo "$source_line" >> "$config_file"
        echo "[INFO] Added environment variables to $config_file"
    else
        echo "[INFO] Environment variables already configured in $config_file"
    fi
}

if [ -f ~/.bashrc ]; then
    add_source_command ~/.bashrc
fi

if [ -f ~/.zshrc ]; then
    add_source_command ~/.zshrc
fi
