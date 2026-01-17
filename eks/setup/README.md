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

### 4. 워크샵 환경 최적화 (선택사항)

```bash
./4.free_idle_pods_for_workshop.sh
```

**⚠️ Workshop Studio에서 `ml.g5.2xlarge` 등 저사양 인스턴스 사용 시에만 실행**

- 불필요한 시스템 Pod 정리 (Kueue, KEDA 등)
- 완료된 Job Pod 삭제  
- Pod 개수 제한으로 인한 배포 실패 해결
- 학습, 배포, task governance 등 핸즈온 실행 전 Pod 슬롯 확보

### 5. 환경 변수 로드

```bash
source ./env_vars
```

## 유틸리티 스크립트

### 가용 Pod 정보 확인

```bash
./check-node-availability.sh
```

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
