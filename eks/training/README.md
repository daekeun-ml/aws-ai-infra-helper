# HyperPod EKS Fine-tuning Hands-on

AWS SageMaker HyperPod EKS 클러스터에서 DeepSeek-R1-Distill-Qwen-1.5B 모델을 LoRA Fine-tuning하는 가이드입니다.

## 사전 요구사항

- AWS CLI 설치 및 구성 완료
- HyperPod EKS 클러스터가 생성되어 있어야 함
- GPU 노드 (g5.8xlarge 이상) 2개 이상
- Kubeflow Training Operator 설치 완료 (HyperPod 기본 제공)
- NVIDIA Device Plugin 설치 완료 (HyperPod 기본 제공)

---

## 📋 전체 실습 순서

이 실습은 `eks/setup` 폴더의 스크립트를 먼저 실행한 후 진행합니다.

```
eks/setup/                              eks/training/
├── 1.create-config-workshop.sh   →     ├── 1.grant_eks_access.sh
├── 2.setup-eks-access.sh               ├── 2.run_training.sh
└── 3.validate-cluster.sh               ├── 3.monitor_training.sh
                                        └── 4.cleanup.sh
```

### Step 0: 환경 설정 (최초 1회)

```bash
# setup 폴더로 이동
cd ../setup

# 1. 환경 변수 설정 (env_vars 파일 생성)
./1.create-config-workshop.sh

# 2. EKS 접근 권한 설정
./2.setup-eks-access.sh

# 3. 클러스터 검증
./3.validate-cluster.sh

# training 폴더로 돌아오기
cd ../training
```

> **Note**: `1.create-config-workshop.sh` 실행 시 생성되는 `env_vars` 파일은 이후 모든 스크립트에서 자동으로 로드됩니다.

---

## 🚀 빠른 시작 (자동화 스크립트)

### 1. 클러스터 접근 설정

```bash
./1.grant_eks_access.sh
```

- `../setup/env_vars` 파일에서 환경 변수 자동 로드
- EKS 클러스터 자동 감지 (단일 클러스터인 경우)
- EKS Access Entry 자동 생성 및 권한 부여
- kubeconfig 자동 설정
- GPU 노드 및 필수 구성요소 확인

> **Note**: 클러스터를 직접 지정하려면: `./1.grant_eks_access.sh [CLUSTER_NAME] [REGION]`

### 2. Fine-tuning 실행

```bash
./2.run_training.sh
```

- 기존 PyTorchJob 확인 및 정리
- PyTorchJob 배포
- Pod 생성 상태 모니터링

### 3. 학습 모니터링

```bash
./3.monitor_training.sh
```

- 실시간 학습 로그 출력
- 학습 진행률 확인
- Job 상태 확인

### 4. 리소스 정리

```bash
./4.cleanup.sh
```

- PyTorchJob 삭제
- 관련 Pod 정리

---

## 📖 상세 가이드 (수동 Step-by-Step)

자동화 스크립트 대신 각 단계를 수동으로 이해하고 실행하려면 아래 가이드를 따르세요.

### Step 1: EKS 클러스터 접속 설정

```bash
# kubeconfig 설정
aws eks update-kubeconfig --name "YOUR_EKS_CLUSTER_NAME" --region us-west-2

# 클러스터 연결 확인
kubectl get nodes
```

### Step 2: GPU 노드 확인

```bash
kubectl get nodes -o custom-columns="NAME:.metadata.name,INSTANCE-TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,GPU:.status.capacity.nvidia\.com/gpu"
```

출력 예시:
```
NAME                           INSTANCE-TYPE   GPU
hyperpod-i-05e4de3dcf4135f28   ml.g5.8xlarge   1
hyperpod-i-0abbe2a2c165f4a8f   ml.g5.8xlarge   1
```

### Step 3: 필수 구성요소 확인

```bash
# Kubeflow Training Operator 확인
kubectl get pods -n kubeflow

# NVIDIA Device Plugin 확인
kubectl get pods -n kube-system | grep nvidia
```

### Step 4: PyTorchJob 배포

```bash
kubectl apply -f template/pytorchjob_finetuning.yaml
```

> **Note**: 이 가이드는 FSx가 없는 환경을 기준으로 합니다. 모델과 데이터는 HuggingFace에서 직접 다운로드됩니다.

### Step 5: Pod 상태 확인

```bash
# Pod 생성 상태 확인
kubectl get pods -l training.kubeflow.org/job-name=deepseek-finetuning

# 상세 이벤트 확인 (이미지 다운로드 등)
kubectl describe pod deepseek-finetuning-worker-0
```

출력 예시:
```
NAME                           READY   STATUS    RESTARTS   AGE
deepseek-finetuning-worker-0   1/1     Running   0          2m
deepseek-finetuning-worker-1   1/1     Running   0          2m
```

### Step 6: 학습 로그 확인

```bash
# Worker 0 로그 확인
kubectl logs -f deepseek-finetuning-worker-0
```

출력 예시:
```
trainable params: 4,358,144 || all params: 1,781,446,144 || trainable%: 0.2446
Loading training data...
Starting training...
{'loss': 14.4461, 'grad_norm': 0.165, 'learning_rate': 3.6e-05, 'epoch': 0.09}
...
```

### Step 7: PyTorchJob 상태 확인

```bash
kubectl get pytorchjob deepseek-finetuning
```

출력 예시:
```
NAME                  STATE       AGE
deepseek-finetuning   Succeeded   7m
```

### Step 8: 리소스 정리

```bash
kubectl delete pytorchjob deepseek-finetuning
```

---

## 📊 학습 설정 커스터마이징

### GPU 수 및 워커 수 변경

`template/pytorchjob_finetuning.yaml`에서 다음 값을 수정합니다:

```yaml
spec:
  nprocPerNode: "1"        # 노드당 GPU 수
  pytorchReplicaSpecs:
    Worker:
      replicas: 2          # 워커 노드 수
```

### LoRA 파라미터 수정

학습 스크립트 내 LoRA 설정:

```python
lora_config = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=16,                    # LoRA rank (높을수록 파라미터 증가)
    lora_alpha=32,           # LoRA alpha
    lora_dropout=0.05,       # Dropout 비율
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
)
```

### 학습 하이퍼파라미터 수정

```python
training_args = TrainingArguments(
    num_train_epochs=1,              # 학습 epoch 수
    per_device_train_batch_size=2,   # GPU당 배치 크기
    gradient_accumulation_steps=4,   # Gradient 누적 스텝
    learning_rate=2e-4,              # 학습률
    warmup_steps=50,                 # Warmup 스텝
)
```

---

## 🔧 문제 해결

### kubectl 연결 안됨

```bash
aws eks update-kubeconfig --name [CLUSTER_NAME] --region us-west-2
```

### Pod가 Pending 상태일 때

```bash
kubectl describe pod deepseek-finetuning-worker-0
```

일반적인 원인:
- GPU 리소스 부족
- 이미지 Pull 실패
- 노드 선택 조건 불일치

### OOM (Out of Memory) 오류

배치 크기 또는 시퀀스 길이를 줄이세요:

```python
per_device_train_batch_size=1    # 2에서 1로 감소
max_length=256                    # 512에서 256으로 감소
```

### 이미지 다운로드가 느린 경우

`huggingface/transformers-pytorch-gpu:latest` 이미지는 약 10GB입니다. 첫 실행 시 다운로드에 5-10분이 소요될 수 있습니다.

```bash
# 이미지 다운로드 상태 확인
kubectl describe pod deepseek-finetuning-worker-0 | grep -A5 "Events:"
```

### PyTorchJob 실패

```bash
# 상세 로그 확인
kubectl describe pytorchjob deepseek-finetuning
kubectl logs deepseek-finetuning-worker-0
```

---

## 📋 유용한 명령어

```bash
# 모든 리소스 상태 확인
kubectl get pods,pytorchjob

# Pod 로그 실시간 확인
kubectl logs -f deepseek-finetuning-worker-0

# 모든 워커 로그 확인
for i in 0 1; do
  echo "=== Worker $i ==="
  kubectl logs deepseek-finetuning-worker-$i --tail=20
done

# GPU 사용량 확인
kubectl exec deepseek-finetuning-worker-0 -- nvidia-smi

# PyTorchJob 상세 정보
kubectl describe pytorchjob deepseek-finetuning
```

---

## 📚 참고 정보

### 학습 구성

| 항목 | 값 |
|------|-----|
| 모델 | DeepSeek-R1-Distill-Qwen-1.5B |
| 학습 방법 | LoRA (Low-Rank Adaptation) |
| 데이터셋 | Alpaca (1000 샘플) |
| Trainable Parameters | 4.3M (0.24%) |
| 예상 학습 시간 | 약 2분 |

### 스토리지 설정

이 가이드는 FSx가 없는 환경을 기준으로 합니다:
- 모델: HuggingFace Hub에서 직접 다운로드
- 데이터: HuggingFace Datasets에서 직접 다운로드
- 출력: emptyDir (Pod 종료 시 삭제)

> **주의**: 학습된 모델을 영구 저장하려면 FSx for Lustre 또는 S3를 사용하세요.

### 참고 문서

- [Kubeflow Training Operator](https://github.com/kubeflow/training-operator)
- [PEFT (Parameter-Efficient Fine-Tuning)](https://github.com/huggingface/peft)
- [DeepSeek-R1 모델](https://huggingface.co/deepseek-ai)
- [SageMaker HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)

---

## 🔄 고급 기능: Auto Restart 및 복원력 (Resiliency)

대규모 분산 학습에서는 하드웨어 장애, 네트워크 문제 등으로 인한 학습 중단이 발생할 수 있습니다. HyperPod EKS 환경에서는 다음과 같은 복원력 기능을 활용할 수 있습니다.

### 1. PyTorchJob의 restartPolicy 설정

`template/pytorchjob_finetuning.yaml`에서 `restartPolicy`를 설정하여 Pod 실패 시 자동 재시작을 구성할 수 있습니다.

```yaml
spec:
  pytorchReplicaSpecs:
    Worker:
      replicas: 2
      restartPolicy: OnFailure    # 실패 시 자동 재시작
```

#### restartPolicy 옵션

| 옵션 | 설명 | 사용 시기 |
|------|------|----------|
| `OnFailure` | Pod 실패 시에만 재시작 | 일반적인 학습 작업 (권장) |
| `Always` | 성공/실패 관계없이 항상 재시작 | 지속적으로 실행해야 하는 서비스 |
| `Never` | 재시작하지 않음 | 디버깅 또는 일회성 작업 |
| `ExitCode` | 특정 exit code에 따라 재시작 결정 | 세밀한 제어가 필요한 경우 |

### 2. Checkpoint 기반 학습 재개

학습 중단 후 처음부터 다시 시작하지 않으려면 **Checkpoint**를 저장하고 재개해야 합니다.

#### YAML 수정: 영구 스토리지 마운트

Checkpoint를 저장하려면 `emptyDir` 대신 **FSx for Lustre** 또는 **EBS**를 사용해야 합니다:

```yaml
spec:
  pytorchReplicaSpecs:
    Worker:
      template:
        spec:
          volumes:
            - name: checkpoint-storage
              persistentVolumeClaim:
                claimName: fsx-claim
          containers:
            - name: pytorch
              volumeMounts:
                - name: checkpoint-storage
                  mountPath: /checkpoint
```

#### 학습 코드 수정: Checkpoint 저장/로드

```python
training_args = TrainingArguments(
    output_dir="/checkpoint/deepseek-finetuning",
    save_steps=100,              # 100 step마다 checkpoint 저장
    save_total_limit=3,          # 최근 3개 checkpoint만 유지
    resume_from_checkpoint=True, # 기존 checkpoint에서 재개
)

trainer.train(resume_from_checkpoint=True)
```

### 3. HyperPod의 자동 노드 복구

SageMaker HyperPod는 클러스터 레벨에서 자동 복구 기능을 제공합니다:

- **Deep Health Checks**: GPU/Trainium 인스턴스에 대해 심층 헬스 체크 수행
- **자동 노드 교체**: 하드웨어 장애 감지 시 자동으로 노드 교체

```bash
# Health Monitoring Agent 확인
kubectl get pods -n aws-hyperpod | grep health-monitoring
```

### 4. 분산 학습에서의 Elastic Training

대규모 학습에서 일부 워커가 실패해도 학습을 계속할 수 있는 Elastic Training:

```yaml
spec:
  elasticPolicy:
    minReplicas: 1        # 최소 워커 수
    maxReplicas: 4        # 최대 워커 수
    rdzvBackend: c10d     # PyTorch rendezvous backend
    maxRestarts: 3        # 최대 재시작 횟수
  pytorchReplicaSpecs:
    Worker:
      replicas: 2
      restartPolicy: OnFailure
```

### 5. 복원력 관련 모니터링

```bash
# PyTorchJob 이벤트 확인
kubectl describe pytorchjob deepseek-finetuning | grep -A20 "Events:"

# Pod 재시작 횟수 확인
kubectl get pods -l training.kubeflow.org/job-name=deepseek-finetuning \
  -o custom-columns="NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount"

# HyperPod 노드 헬스 상태 확인
kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status"
```

### 복원력 체크리스트

| 항목 | 설정 | 확인 |
|------|------|------|
| restartPolicy | `OnFailure` 설정 | ✅ |
| Checkpoint | 영구 스토리지에 저장 | ✅ |
| resume_from_checkpoint | 학습 코드에 추가 | ✅ |
| elasticPolicy | 필요시 설정 | ⬜ |
| Health Monitoring | HyperPod 기본 제공 | ✅ |
