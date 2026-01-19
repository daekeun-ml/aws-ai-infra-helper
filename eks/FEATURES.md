# SageMaker HyperPod EKS 

## SageMaker HyperPod EKS란?

**SageMaker HyperPod EKS**는 대규모 Foundation Model 학습 및 추론을 위해 설계된 AWS의 관리형 인프라 솔루션입니다. Amazon EKS(Elastic Kubernetes Service)를 기반으로 하되, 수백~수천 개의 GPU/Trainium 가속기를 사용하는 분산 ML 워크로드에 필수적인 복원력(resiliency) 기능과 자동화된 인프라 관리를 제공합니다.

### 핵심 가치 제안

**문제**: 대규모 ML 학습에서 하드웨어 장애는 필연적입니다. [Meta Llama 3 405B 모델](https://ai.meta.com/research/publications/the-llama-3-herd-of-models/)을 16,000개 H100 GPU로 54일간 학습했을 때 419회의 중단이 발생했고, 78%가 하드웨어 문제였습니다. 단 하나의 GPU 장애로도 전체 학습이 중단될 수 있습니다.

**해결책**: HyperPod는 장애를 자동으로 감지하고, 문제 노드를 교체하며, 마지막 체크포인트에서 학습을 자동으로 재개합니다. 엔지니어의 수동 개입 없이 24시간 무중단 학습이 가능합니다.

### 주요 특징

1. **자동화된 복원력**: Deep Health Check로 문제 GPU 사전 차단, 실시간 모니터링으로 장애 자동 감지 및 노드 교체
2. **작업 자동 재개**: Kubeflow Training Operator 통합으로 장애 발생 시 체크포인트에서 자동 재시작
3. **관리형 인프라**: Kubernetes 클러스터 구축, 설정, 모니터링, 유지보수를 AWS가 담당
4. **ML 최적화**: EFA 네트워크, FSx for Lustre, SageMaker 분산 학습 라이브러리 등 사전 구성
5. **유연한 오케스트레이션**: Slurm과 EKS 간 원활한 전환, HyperPod CLI로 간편한 작업 관리

### 적합한 사용 사례

- 수백~수천 개 GPU를 사용하는 Foundation Model 사전 학습
- 몇 주~몇 달간 실행되는 장기 학습 작업
- 하드웨어 장애가 치명적인 프로덕션 ML 워크로드
- Kubernetes 기반 ML 워크플로우를 표준화한 조직
- 인프라 관리 부담을 최소화하고 모델 개발에 집중하려는 팀

## EKS와 SageMaker HyperPod EKS의 주요 차이점

### 1. 목적과 대상 워크로드

**Amazon EKS**
- 범용 컨테이너 오케스트레이션 플랫폼
- 다양한 애플리케이션 워크로드 지원
- 마이크로서비스, 웹 애플리케이션, 배치 처리 등 일반적인 컨테이너 워크로드에 적합

**SageMaker HyperPod EKS**
- 대규모 Foundation Model(FM) 학습 및 추론에 특화
- 수백~수천 개의 GPU/Trainium 가속기를 사용하는 분산 ML 워크로드에 최적화
- ML 모델 개발 라이프사이클 전반을 지원

### 2. 복원력(Resiliency) 기능

**Amazon EKS**
- 기본적인 Kubernetes 복원력 기능 제공
- 컨트롤 플레인의 고가용성(다중 가용영역 운영)
- 표준 Kubernetes 자가 치유(self-healing) 메커니즘

**SageMaker HyperPod EKS**
- **Deep Health Checks**: GPU, Trainium 인스턴스 및 EFA(Elastic Fabric Adapter) 네트워크에 대한 심층 스트레스 테스트 수행
- **Automated Node Recovery**: 메모리 고갈, 디스크 장애, GPU 이상, 커널 데드락 등을 지속적으로 모니터링하고 자동으로 노드 교체 또는 재부팅
- **Job Auto Resume**: 하드웨어 장애 발생 시 마지막 체크포인트에서 자동으로 학습 작업 재개
- Meta Llama 3 405B 사전 학습 사례에서 54일간 419회의 예상치 못한 중단 중 78%가 하드웨어 문제였던 것처럼, 대규모 학습에서 발생하는 하드웨어 장애에 대응

### 3. 인프라 관리

**Amazon EKS**
- 사용자가 워커 노드(EC2 인스턴스 또는 Fargate) 직접 관리
- 노드 그룹 생성, 스케일링, 업데이트를 사용자가 구성
- 표준 Kubernetes 도구(kubectl 등) 사용

**SageMaker HyperPod EKS**
- HyperPod 관리형 컴퓨트를 EKS 클러스터에 워커 노드로 자동 추가
- SageMaker API 및 콘솔을 통한 노드 그룹 관리
- 라이프사이클 스크립트를 통한 추가 종속성 자동 설치
- SSH 접근 및 클러스터 소프트웨어 업데이트 API 제공
- 운영 비용을 30% 이상 절감 가능(Observea 사례)

### 4. 아키텍처 구성

**Amazon EKS**
- EKS 컨트롤 플레인(AWS 관리형 VPC)
- 사용자 VPC의 워커 노드
- 표준 Kubernetes 네트워킹

**SageMaker HyperPod EKS**
- EKS 컨트롤 플레인(AWS 관리형 VPC)
- HyperPod 컴퓨트(별도의 AWS 관리형 VPC)
- 사용자 VPC(FSx for Lustre, S3 등 리소스)
- 크로스 계정 ENI를 통한 통신
- 1:1 매핑 구조(하나의 EKS 클러스터 = 하나의 HyperPod 컴퓨트)

### 5. ML 특화 기능

**Amazon EKS**
- 기본 Kubernetes 기능만 제공
- ML 도구는 사용자가 직접 설치 및 구성

**SageMaker HyperPod EKS**
- **HyperPod CLI**: YAML 파일로 학습 작업 제출 및 관리(kubectl 없이도 가능)
- **Kubeflow Training Operator**: PyTorch 분산 학습 자동 복구
- **SageMaker 분산 학습 라이브러리**: 최대 20% 성능 향상
- **Managed MLflow**: 실험 및 학습 실행 관리
- **Kueue 통합**: 작업 큐잉 지원
- **Container Insights**: GPU, Trainium, EFA, 파일시스템까지 컨테이너 수준의 상세 메트릭 제공

### 6. 사용자 경험

**Amazon EKS**
- Kubernetes 전문 지식 필요
- kubectl 및 Kubernetes 매니페스트 작성 필수
- 인프라 관리에 상당한 시간 투자 필요

**SageMaker HyperPod EKS**
- **관리자**: SageMaker API/콘솔로 간편한 노드 관리, 라이프사이클 스크립트 지원
- **데이터 과학자**: HyperPod CLI로 kubectl 없이도 작업 관리 가능, Slurm과 EKS 간 원활한 전환
- 차별화되지 않은 인프라 관리 부담 대폭 감소

### 7. 모니터링 및 관찰성

**Amazon EKS**
- CloudWatch Container Insights 기본 메트릭
- 사용자가 추가 모니터링 도구 구성 필요

**SageMaker HyperPod EKS**
- 향상된 Container Insights: CPU, GPU, Trainium, EFA, 파일시스템까지 상세 메트릭
- 노드 상태(Schedulable/Unschedulable) 실시간 추적
- Deep Health Check 및 Health Monitoring Agent 로그를 CloudWatch에 자동 저장
- 개별 노드 상태 및 스케줄 가능/불가능 노드 수 대시보드 제공

## 사용 사례

### Amazon EKS 적합 사례
- 일반적인 컨테이너화된 애플리케이션
- 마이크로서비스 아키텍처
- 웹 애플리케이션 및 API 서버
- 소규모 ML 워크로드

### SageMaker HyperPod EKS 적합 사례
- 대규모 Foundation Model 사전 학습
- 수백~수천 개 GPU를 사용하는 분산 학습
- 장시간 실행되는 ML 학습 작업(하드웨어 장애 위험 높음)
- 고성능 추론 환경(KV Cache, Intelligent Routing)
- Kubernetes 기반 ML 워크플로우를 표준화한 조직

## 요약

SageMaker HyperPod EKS는 Amazon EKS의 모든 기능을 포함하면서, 대규모 ML 워크로드에 필수적인 자동화된 복원력, 심층 헬스 체크, 작업 자동 재개 기능을 추가로 제공합니다. 일반적인 컨테이너 워크로드에는 Amazon EKS가 적합하지만, 수천 개의 GPU를 사용하는 Foundation Model 학습처럼 하드웨어 장애가 치명적인 대규모 ML 워크로드에는 SageMaker HyperPod EKS가 훨씬 더 적합한 선택입니다.

## 참고 자료

- [Introducing Amazon EKS support in Amazon SageMaker HyperPod](https://aws.amazon.com/blogs/machine-learning/introducing-amazon-eks-support-in-amazon-sagemaker-hyperpod/)
- [Architecture of AWS EKS](https://dev.to/haythammostafa/architecture-of-aws-eks-44am)
- [AWS EKS Architecture: Clusters, Nodes, and Networks](https://www.netapp.com/learn/aws-cvo-blg-aws-eks-architecture-clusters-nodes-and-networks/)
