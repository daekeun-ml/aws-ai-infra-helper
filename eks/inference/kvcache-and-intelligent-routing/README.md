# SageMaker HyperPod Inference: KV Cache & Intelligent Routing 벤치마크

AWS SageMaker HyperPod의 Managed Tiered KV Cache와 Intelligent Routing 기능을 실제로 테스트하고 성능을 측정하는 종합 벤치마크입니다.

## 📚 참고 자료

### AWS 공식 문서
- [Managed Tiered KV Cache and Intelligent Routing 블로그](https://aws.amazon.com/blogs/machine-learning/managed-tiered-kv-cache-and-intelligent-routing-for-amazon-sagemaker-hyperpod/)
- [HyperPod Model Deployment 가이드](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-model-deployment.html)
- [HyperPod Cluster Setup](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-model-deployment-setup.html)

## 🎯 주요 기능

### 1. Managed Tiered KV Cache
- **L1 Cache**: CPU 메모리 (로컬, 빠른 접근)
- **L2 Cache**: 클러스터 전체 공유 캐시
  - **tieredstorage** (권장): AWS 최적화, 테라바이트 규모, GPU-aware, zero-copy
  - **redis**: 소규모 워크로드용

### 2. Intelligent Routing 전략

| 전략 | 설명 | 최적 사용 사례 |
|------|------|----------------|
| **prefix-aware** (기본) | 프리픽스 트리로 캐시 위치 추적 | 멀티턴 대화, 고객 서비스 봇, 공통 템플릿 |
| **kv-aware** | 중앙 컨트롤러로 실시간 캐시 관리 | 긴 대화, 문서 처리, 확장 코딩 세션 |
| **round-robin** | 균등 분산 | 배치 추론, 상태 없는 API, 로드 테스트 |

## 📊 AWS 공식 벤치마크 결과

### 중간 컨텍스트 (8K 토큰)
- TTFT P90: **40% 감소**
- TTFT P50: **72% 감소**
- Throughput: **24% 증가**
- Cost: **21% 절감**

### 긴 컨텍스트 (64K 토큰)
- TTFT P90: **35% 감소**
- TTFT P50: **94% 감소**
- Throughput: **38% 증가**
- Cost: **28% 절감**

## 🚀 빠른 시작

### 사전 준비사항
1. SageMaker HyperPod 클러스터 (EKS 오케스트레이션)
2. Inference Operator 설치 완료
3. AWS CLI 및 kubectl 설정

### 단계별 가이드

#### 1. 도구 설치 (선택사항)
```bash
# kubectl, eksctl, helm 설치
./install_tools.sh
```

#### 2. S3 버킷 생성 및 모델 복사
```bash
# S3 버킷 생성, 버킷 정책 설정, 모델 복사
./1.copy_to_s3.sh

# S3_BUCKET 환경변수 설정 (출력된 버킷 이름 사용)
export S3_BUCKET=hyperpod-inference-xxxxx-us-west-2
```

#### 3. S3 CSI Driver 설정
```bash
# S3 CSI Driver IAM 권한 설정 (필수)
./2.setup_s3_csi.sh

# 1-2분 대기 후 상태 확인
kubectl get pods -n kube-system | grep s3-csi
```

#### 4. 엔드포인트 배포
```bash
# inference_endpoint_config.yaml 생성 및 배포
./3.prepare.sh

# 배포 완료까지 약 5-10분 소요
# - S3에서 모델 다운로드
# - 컨테이너 이미지 pull
# - 모델 로딩 및 초기화
```

#### 5. 상태 확인
```bash
# 엔드포인트 및 Pod 상태 확인
./4.check_status.sh

# 또는 수동 확인
kubectl get inferenceendpointconfig demo -n default
kubectl get pods -n default
kubectl describe inferenceendpointconfig demo -n default

# Pod 상태가 "3/3 Running"이 될 때까지 대기 (약 5-10분)
watch kubectl get pods -n default
```

#### 6. 배포 완료 확인 및 테스트
```bash
# Pod가 모두 Running 상태가 되면 테스트
# Worker Pod: 3/3 Running 확인 필수

# 간단한 테스트
python invoke.py

# 종합 벤치마크 (동시 요청 20건)
python benchmark.py
```

**배포 시간:**
- 초기 배포: 약 5-10분 소요
  - S3 모델 다운로드: 2-3분
  - 컨테이너 초기화: 1-2분
  - 모델 로딩: 2-5분
- 재배포: 약 3-5분 (캐시된 이미지 사용)

### 엔드포인트 설정 예시

`inference_endpoint_config.yaml`:
```yaml
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: demo
  namespace: default
spec:
  modelName: Llama-3.1-8B-Instruct
  instanceType: ml.g5.24xlarge
  replicas: 1
  invocationEndpoint: v1/chat/completions
  
  # KV Cache 설정
  kvCacheSpec:
    enableL1Cache: true
    enableL2Cache: true
    l2CacheSpec:
      l2CacheBackend: "tieredstorage"  # 권장
  
  # Intelligent Routing 설정
  intelligentRoutingSpec:
    enabled: true
    routingStrategy: prefixaware  # prefix-aware, kv-aware, round-robin
  
  modelSourceConfig:
    modelSourceType: s3
    s3Storage:
      bucketName: my-model-bucket
      region: us-west-2
    modelLocation: models/Llama-3.1-8B-Instruct
  
  worker:
    resources:
      limits:
        nvidia.com/gpu: "4"
      requests:
        cpu: "6"
        memory: 30Gi
        nvidia.com/gpu: "4"
    image: public.ecr.aws/deep-learning-containers/vllm:0.11.1-gpu-py312-cu129-ubuntu22.04-ec2-v1.0
    args:
      - "--model"
      - "/opt/ml/model"
      - "--max-model-len"
      - "20000"
      - "--tensor-parallel-size"
      - "4"
```

## 📈 벤치마크 측정 항목

### 1. TTFT (Time To First Token)
- P50, P90, P95, P99 백분위수
- Cold Cache vs Warm Cache 비교

### 2. Throughput (TPS)
- Tokens Per Second
- Cold Cache vs Warm Cache 비교

### 3. Cost Analysis
- Cost per 1K tokens
- Input/Output 토큰별 비용 계산

### 4. Prefix-aware Routing 효과
- 같은 Prefix 반복 vs 다른 Prefix
- 캐시 히트율 측정

## 💡 핵심 발견

### KV Cache 효과
- **첫 요청**: 캐시 미스 (느림)
- **이후 요청**: 캐시 히트 (40-50% 빠름)
- **L2 Cache 공유**: 모든 워커가 캐시 공유

### Prefix-aware Routing
- 같은 prefix → 같은 워커 → KV Cache 재사용
- 다른 prefix → 다른 워커 → 캐시 미스
- 멀티턴 대화, 문서 Q&A에 최적

## 🎓 실제 사용 사례

### 1. 문서 Q&A 시스템
```python
# 긴 문서를 컨텍스트로 제공
DOCUMENT = "... 매우 긴 문서 내용 ..."

# 여러 질문 (같은 컨텍스트 재사용)
for question in questions:
    response = invoke_endpoint(
        messages=[{"role": "user", "content": f"{DOCUMENT}\n\n{question}"}]
    )
```

### 2. 코드 리뷰 어시스턴트
```python
# 긴 코드베이스를 컨텍스트로
CODE = "... 전체 코드 ..."

# 여러 리뷰 질문
for review_question in review_questions:
    response = invoke_endpoint(
        messages=[{"role": "user", "content": f"{CODE}\n\n{review_question}"}]
    )
```

### 3. 채팅 애플리케이션
```python
# 대화 히스토리 누적
conversation_history = []

for user_message in user_messages:
    conversation_history.append({"role": "user", "content": user_message})
    
    response = invoke_endpoint(messages=conversation_history)
    
    conversation_history.append({"role": "assistant", "content": response})
```

## 🔧 문제 해결

### 배포 상태 확인
```bash
# 실시간 상태 모니터링
watch kubectl get pods -n default

# 상세 로그 확인
kubectl logs -l app=demo -n default -f

# 이벤트 확인
kubectl get events -n default --sort-by='.lastTimestamp'
```

### 일반적인 문제

**1. S3 권한 오류**
- `2.setup_s3_csi.sh`가 자동으로 권한 설정
- 수동 확인: IAM 역할에 S3 접근 권한 확인

**2. Pod가 ContainerCreating 상태에서 멈춤**
- S3 마운트 문제일 가능성
- S3 CSI Driver pods 확인: `kubectl get pods -n kube-system | grep s3-csi`
- Mountpoint logs 확인: `kubectl logs -n mount-s3 <pod-name>`

**3. 모델 로딩 시간이 오래 걸림**
- 정상: 첫 배포는 5-10분 소요
- Worker logs 확인: `kubectl logs -l app=demo -n default`

### 엔드포인트 삭제
```bash
# 전체 엔드포인트 삭제
./cleanup.sh

# S3 버킷도 함께 삭제
export S3_BUCKET=hyperpod-inference-xxxxx-us-east-2
./cleanup.sh

# 또는 수동 삭제
kubectl delete inferenceendpointconfig demo -n default
```

### Pod 재시작 (캐시 초기화)
```bash
# Pod만 삭제 (자동으로 재생성됨)
kubectl delete pod <pod-name> -n default
```

## 📁 파일 구성

```
.
├── install_tools.sh                   # kubectl, eksctl, helm 설치
├── 1.copy_to_s3.sh                    # S3 버킷 생성 및 모델 복사
├── 2.setup_s3_csi.sh                  # S3 CSI Driver 설정
├── 3.prepare.sh                       # 엔드포인트 배포
├── 4.check_status.sh                  # 상태 확인
├── cleanup.sh                         # 엔드포인트 삭제
├── invoke.py                          # 간단한 테스트 스크립트
├── benchmark.py                       # 종합 벤치마크
└── README.md                          # README
```

## 🔗 추가 리소스

- [AWS SageMaker HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- [HyperPod Inference Operator](https://awslabs.github.io/ai-on-sagemaker-hyperpod/docs/eks-blueprints/inference/inference-operator/)
- [HyperPod CLI & SDK](https://docs.aws.amazon.com/sagemaker/latest/dg/getting-started-hyperpod-training-deploying-models.html)

## 📝 라이선스

이 프로젝트는 AWS 샘플 코드의 일부입니다.

## 🤝 기여

이슈와 PR을 환영합니다!

---

**참고**: 이 벤치마크는 실제 프로덕션 환경에서의 성능을 보장하지 않습니다. 워크로드와 설정에 따라 결과가 달라질 수 있습니다.
