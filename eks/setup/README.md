# HyperPod Cluster w/ EKS 생성 후 추가 설정 (easy-ssh)

HyperPod EKS 클러스터 생성 후 필요한 추가 설정을 위한 스크립트 모음입니다.

## 사전 요구사항

- AWS CLI 설치 및 구성
- HyperPod EKS 클러스터가 이미 생성되어 있어야 함
- kubectl과 helm은 스크립트에서 자동 설치됩니다

## 실행 순서

### 1. 환경 설정 생성

```bash
# 일반 AWS 계졍
./1.create-config.sh

# 핸즈온 워크샵용 (Workshop Studio)
./1.create-config-workshop.sh
```

- SageMaker HyperPod 리소스 정보 추출
- 환경 변수를 `env_vars` 파일에 저장

### 2. EKS 클러스터 접근 권한 설정

```bash
./2.setup-eks-access.sh
```

- 현재 사용자 ARN 확인
- EKS 클러스터 접근 엔트리 생성 (기존 엔트리 확인)
- 클러스터 관리자 정책 연결 (기존 정책 확인)
- kubectl 자동 설치 및 kubeconfig 업데이트

### 3. 클러스터 검증

```bash
./3.validate-cluster.sh
```

- Helm 자동 설치
- 클러스터 연결 상태 확인
- 노드, GPU, EFA 가용성 확인
- Kubeflow Training Operator 상태 확인
- 스토리지 클래스 및 권한 검증


### 4. 환경 변수 로드

```bash
source ./env_vars
```

## 유틸리티 스크립트

### NodeGroup 정보 확인

```bash
./check-nodegroup.sh
```

- EKS 클러스터 및 NodeGroup 정보 조회
- 인스턴스 타입, 스케일링 설정 확인
- 노드별 Pod 수 확인

## 환경 변수

스크립트 실행 시 다음 환경 변수가 사용됩니다:

- `AWS_REGION`: AWS 리전 (자동 감지 가능)
- `STACK_ID`: CloudFormation 스택 이름 (자동 검색 가능)
- `EKS_CLUSTER_NAME`: EKS 클러스터 이름 (자동 추출)

## 문제 해결

- 환경 변수 미인식: `1.create-config-workshop.sh` 실행
- 권한 오류 발생 시: IAM 역할에 EKS 관리 권한이 있는지 확인
- 클러스터 연결 실패 시: kubeconfig가 올바르게 설정되었는지 확인
- 여러 클러스터가 있는 경우: 스크립트가 자동으로 선택 옵션을 제공합니다.
- kubectl/helm이 없는 경우: 스크립트가 자동으로 설치합니다.

---

> **Note - 2026년 1월 18일 워크샵 환경에서 실행하는 경우**
>
> `3.validate-cluster.sh` 실행 시 `❌ No nodes found` 에러가 발생할 수 있습니다.
>
> **원인**: S3 버킷의 `on_create.sh`가 존재하지 않는 `on_create_main.sh`를 호출하여 Lifecycle 스크립트 실패
>
> **해결 방법**:
>
> 1. 올바른 Lifecycle 스크립트 업로드:
> ```bash
> source env_vars
> aws s3 cp \
>   ../../build/awsome-distributed-training/1.architectures/7.sagemaker-hyperpod-eks/LifecycleScripts/base-config/on_create.sh \
>   s3://${S3_BUCKET_NAME}/on_create.sh
> ```
>
> 2. 클러스터 업데이트로 노드 재프로비저닝:
> ```bash
> aws sagemaker update-cluster \
>   --cluster-name ${HYPERPOD_CLUSTER_NAME} \
>   --instance-groups '[{
>     "InstanceGroupName": "accelerated-worker-group-1",
>     "InstanceType": "ml.g5.8xlarge",
>     "InstanceCount": 2,
>     "LifeCycleConfig": {
>       "SourceS3Uri": "s3://'"${S3_BUCKET_NAME}"'/",
>       "OnCreate": "on_create.sh"
>     },
>     "ExecutionRole": "arn:aws:iam::'"$(aws sts get-caller-identity --query Account --output text)"':role/sagemaker-hyperpod-eks-SMHP-Exec-Role-'"${AWS_REGION}"'",
>     "ThreadsPerCore": 1,
>     "InstanceStorageConfigs": [{"EbsVolumeConfig": {"VolumeSizeInGB": 500}}]
>   }]' \
>   --region ${AWS_REGION}
> ```
>
> > "Unable to update cluster as there are no changes" 에러 시 `SourceS3Uri` 끝의 `/`를 추가/제거 후 재실행
>
> 3. 노드 프로비저닝 대기 (약 3-5분):
> ```bash
> watch -n 10 "aws sagemaker describe-cluster \
>   --cluster-name ${HYPERPOD_CLUSTER_NAME} \
>   --region ${AWS_REGION} \
>   --query 'InstanceGroups[*].{Name:InstanceGroupName,Current:CurrentCount,Target:TargetCount}' \
>   --output table"
> ```
>
> 4. 노드 확인 후 validation 재실행:
> ```bash
> kubectl get nodes
> ./3.validate-cluster.sh
> ```
