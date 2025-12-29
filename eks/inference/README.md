# HyperPod EKS Inference Hands-on

AWS SageMaker HyperPod EKS 클러스터에서 HyperPod Inference Operator를 활용한 AI/ML 모델 추론 솔루션을 제공합니다.

## 🎯 HyperPod Inference w/ EKS 특장점

### 📋 HyperPod Inference Operator 개요

SageMaker HyperPod는 대규모 파운데이션 모델 개발을 위해 복원력을 핵심으로 설계된 목적별 인프라입니다. 이제 EKS 지원을 통해 훈련, 파인튜닝, 배포를 동일한 HyperPod 컴퓨팅 리소스에서 수행할 수 있어 전체 모델 라이프사이클에서 리소스 활용도를 극대화합니다.

Kubernetes를 생성형 AI 전략의 일부로 활용하는 고객들은 유연성, 이식성, 오픈소스 프레임워크의 장점을 누릴 수 있습니다. HyperPod는 친숙한 Kubernetes 워크플로우를 유지하면서 파운데이션 모델을 위해 특별히 구축된 고성능 인프라에 접근할 수 있게 합니다.

그러나 Kubernetes에서 대규모 파운데이션 모델 추론을 실행하는 것은 여러 도전과제를 수반합니다: 모델의 안전한 다운로드, 최적 성능을 위한 적절한 컨테이너와 프레임워크 식별, 올바른 배포 구성, 적절한 GPU 타입 선택, 로드 밸런서 프로비저닝, 관찰성 구현, 수요 급증에 대응하는 자동 스케일링 정책 추가 등입니다.

HyperPod Inference Operator는 이러한 복잡성을 해결하여 인프라 설정을 간소화하고, 고객이 백엔드 복잡성 관리보다는 모델 제공에 더 집중할 수 있도록 합니다.

#### **핵심 기능**
- **원클릭 JumpStart 배포**: 400+ 오픈소스 파운데이션 모델 (DeepSeek-R1, Mistral, Llama4 등) 원클릭 배포
- **다중 배포 소스**: SageMaker JumpStart, S3, FSx Lustre에서 모델 배포 지원
- **유연한 배포 방식**: kubectl, HyperPod CLI, Python SDK를 통한 다양한 배포 옵션
- **자동 인프라 프로비저닝**: 적절한 인스턴스 타입 식별, 모델 다운로드, ALB 구성 자동화

#### **고급 스케일링 & 관리**
- **동적 오토스케일링**: CloudWatch 및 Prometheus 메트릭 기반 KEDA 자동 스케일링
- **Task Governance**: 추론과 훈련 워크로드 간 우선순위 기반 리소스 할당
- **SageMaker 엔드포인트 통합**: 기존 SageMaker 호출 패턴과 완벽 호환

#### **포괄적 관찰성**
- **플랫폼 메트릭**: GPU 사용률, 메모리 사용량, 노드 상태
- **추론 전용 메트릭**: 
  - `model_invocations_total`: 총 모델 호출 수
  - `model_latency_milliseconds`: 모델 응답 지연시간
  - `model_ttfb_milliseconds`: 첫 바이트까지의 시간
  - `model_concurrent_requests`: 동시 요청 수

#### **엔터프라이즈 보안 & 네트워킹**
- **TLS 인증서 자동 관리**: S3 저장 및 ACM 통합
- **Application Load Balancer**: 자동 프로비저닝 및 라우팅 구성
- **HTTPS 지원**: 클라이언트 보안 연결 지원

### 🚀 핵심 이점

#### 1. **관리형 복원력 (Managed Resiliency)**
- **Deep Health Checks**: GPU/Trainium 인스턴스 스트레스 테스트
- **자동 노드 복구**: 하드웨어 장애 시 자동 노드 교체/재부팅
- **Job Auto Resume**: 중단 시 체크포인트에서 자동 재시작

#### 2. **Kubernetes 생태계 활용**
- **EKS 통합**: 관리형 Kubernetes 컨트롤 플레인 활용
- **네이티브 도구**: kubectl, Helm, Kustomize 등 표준 도구 사용
- **확장성**: KubeRay, Kueue 등 서드파티 도구 지원

#### 3. **운영 효율성**
- **30% 비용 절감**: 인프라 관리 오버헤드 감소
- **40% 훈련 시간 단축**: 내장 복원력으로 중단 최소화
- **통합 관리**: 훈련과 추론을 동일한 클러스터에서 관리

## 📁 HyperPod EKS 추론 Hands-on 구성

### 🔰 [Basic](./basic/)
기본적인 HyperPod EKS 추론 환경 구성
- HyperPod Inference Operator 기반 배포
- FSx Lustre 및 S3 CSI를 이용한 모델 저장소
- JumpStart 모델 및 커스텀 모델 지원
- 자동화 스크립트 및 상세 가이드

### 🚀 [KV Cache & Intelligent Routing](./kvcache-and-intelligent-routing/)
고급 추론 최적화 기능
- Managed Tiered KV Cache (L1/L2 캐시)
- Intelligent Routing 전략
- 대규모 모델 최적화
- 고성능 벤치마크

## 🛠 공통 도구 (Optional)

```bash
# 디펜던시 설치 (kubectl, eksctl, helm)
./install_tools.sh

# FSx 탐색
./explore_fsx.sh

# SageMaker JumpStart 모델 탐색
./list-sagemaker-jumpstart-models.py
```

### 📋 SageMaker JumpStart 모델 탐색 도구

`list-sagemaker-jumpstart-models.py`는 SageMaker JumpStart에서 사용 가능한 모델 및 지원 인스턴스 타입을 검색하는 도구입니다.

#### 사용법

```bash
# 모든 JumpStart 모델 목록 조회
./list-sagemaker-jumpstart-models.py --list

# 모델 총 개수만 확인
./list-sagemaker-jumpstart-models.py --count

# 특정 키워드로 모델 검색 (단순 목록)
./list-sagemaker-jumpstart-models.py --search mistral
./list-sagemaker-jumpstart-models.py --search llama

# 인터랙티브 검색 (모델 선택 및 상세 정보)
./list-sagemaker-jumpstart-models.py --search-interactive deepseek
./list-sagemaker-jumpstart-models.py -si llama

# 특정 모델의 지원 인스턴스 타입 확인
./list-sagemaker-jumpstart-models.py --instances huggingface-llm-mistral-7b-instruct
./list-sagemaker-jumpstart-models.py -i meta-textgeneration-llama-2-7b-f

# 도움말 보기
./list-sagemaker-jumpstart-models.py --help
```

#### 주요 기능
- **전체 모델 목록**: JumpStart 모델 및 지원 인스턴스 타입 조회
- **키워드 검색**: 모델명 기반 검색 (대소문자 구분 없음)
- **인터랙티브 검색**: 검색 결과에서 모델 선택 및 상세 정보 확인
- **인스턴스 타입 조회**: 모델별 기본/지원 인스턴스 타입 확인
- **모델 개수 확인**: 사용 가능한 총 모델 수 표시

## 🚀 빠른 시작

1. **Basic 추론 환경**: HyperPod Inference Operator를 활용한 기본 모델 서빙은 [`basic/`](./basic/) 폴더를 참고하세요.

2. **고급 최적화**: KV Cache와 Intelligent Routing을 활용한 고성능 추론은 [`kvcache-and-intelligent-routing/`](./kvcache-and-intelligent-routing/) 폴더를 참고하세요.

## 📋 사전 요구사항

- AWS CLI 구성 및 적절한 IAM 권한
- kubectl, eksctl, helm 설치
- SageMaker HyperPod EKS 클러스터
- HyperPod Inference Operator 설치

## 🔗 관련 문서

- [HyperPod EKS 지원 소개](https://aws.amazon.com/blogs/machine-learning/introducing-amazon-eks-support-in-amazon-sagemaker-hyperpod/)
- [HyperPod 모델 배포 설정](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-model-deployment-setup.html)
- [HyperPod EKS 클러스터 생성](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-eks-operate-console-ui-create-cluster.html)

각 솔루션별 상세한 요구사항과 설정 방법은 해당 폴더의 README를 참고하세요.
