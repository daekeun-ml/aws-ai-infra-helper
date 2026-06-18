# HyperPod EKS Fine-tuning Hands-on

AWS SageMaker HyperPod EKS 클러스터에서 **DeepSeek-R1-Distill-Qwen-1.5B** 모델을 **LoRA Fine-tuning**하는 가이드입니다. Kubeflow Training Operator의 **PyTorchJob**으로 분산 학습을 실행합니다.

<details>
<summary>📖 <b>처음이신가요? 기본 용어 먼저 보기 (클릭해서 펼치기)</b></summary>

<br>

이 가이드에 자주 나오는 용어들을 쉽게 정리했습니다. 이미 익숙하다면 건너뛰어도 됩니다.

### 인프라 / 쿠버네티스 기본

| 용어 | 쉬운 설명 |
|---|---|
| **EKS** (Elastic Kubernetes Service) | AWS가 관리해 주는 **쿠버네티스** 클러스터. 컨테이너(앱)를 여러 서버에 띄우고 관리합니다. |
| **HyperPod** | SageMaker의 대규모 ML 학습·추론용 인프라. 여기서는 **EKS 기반 HyperPod** 클러스터를 씁니다. |
| **노드(Node)** | 실제 작업이 도는 서버(EC2 인스턴스) 1대. 예: `ml.g5.2xlarge`(GPU 1개). |
| **Pod** | 컨테이너를 실행하는 **가장 작은 단위**. "앱 1개 = Pod 1개"로 보면 됩니다. |
| **kubectl** | 쿠버네티스를 조작하는 명령줄 도구. (`kubectl get pods` = Pod 목록) |
| **kubeconfig** | 내 PC가 어느 클러스터에 어떻게 접속할지 적힌 설정 파일. |

### 학습 / 분산 트레이닝

| 용어 | 쉬운 설명 |
|---|---|
| **Kubeflow Training Operator** | 쿠버네티스에서 분산 ML 학습을 관리해 주는 컨트롤러. `PyTorchJob` 같은 리소스를 처리합니다. |
| **PyTorchJob** | Training Operator가 읽는 커스텀 리소스(CRD). "이 컨테이너를 worker 몇 개로 분산 학습해라"를 정의합니다. |
| **Worker / replicas** | 분산 학습에 참여하는 Pod. `replicas: 2`면 worker 2개(보통 GPU 2개)로 나눠 학습합니다. |
| **LoRA** (Low-Rank Adaptation) | 모델 전체가 아니라 **작은 추가 가중치만** 학습하는 효율적 fine-tuning 기법. 메모리·시간 절약. |
| **PEFT** | LoRA 같은 "파라미터 효율적 fine-tuning"을 구현한 HuggingFace 라이브러리. |
| **Epoch / Step / Loss** | epoch=데이터 전체 1회 학습, step=배치 1회 업데이트, loss=오차(작아질수록 학습 잘 됨). |

### 리소스 / 권한

| 용어 | 쉬운 설명 |
|---|---|
| **GPU 요청(`nvidia.com/gpu`)** | Pod가 GPU를 몇 개 쓸지 선언. worker당 1개면 worker 2개 = GPU 2개 필요. |
| **requests / limits** | Pod가 요구하는(requests)·최대로 쓸 수 있는(limits) CPU/메모리/GPU 양. requests가 노드 용량보다 크면 **스케줄 불가(Pending)**. |
| **allocatable** | 노드의 물리 용량에서 시스템 예약분을 뺀, **실제 Pod에 줄 수 있는** 양. (예: g5.2xlarge는 8 vCPU지만 allocatable은 ~7.9 vCPU) |
| **IAM Role / Access Entry** | AWS 권한 묶음 / 그 신원을 EKS 클러스터 접근 목록에 등록하는 것. |

</details>

<details>
<summary>🤔 <b>이 절차는 왜 필요한가? (전체 흐름과 각 단계의 이유)</b></summary>

<br>

### 🎯 최종 목표

> **GPU 노드 여러 대에 걸쳐 DeepSeek 모델을 LoRA로 분산 fine-tuning하고, 결과를 확인하는 것.**

이 목표를 위해 아래 단계가 순서대로 필요합니다. 각 스크립트가 하나씩 담당합니다.

### 1️⃣ 클러스터에 접근할 권한 — `1.grant_eks_access.sh`

**왜?** EKS 클러스터는 보안상 **만든 사람 외에는 `kubectl` 접근을 기본 차단**합니다. 내 IAM 신원을 클러스터의 **Access Entry**로 등록하고 관리자 정책을 연결해야 `kubectl get nodes`조차 동작합니다.
→ 안 하면: `error: You must be logged in to the server (Unauthorized)`

### 2️⃣ 학습 잡 정의·실행 — `2.run_training.sh`

**왜 PyTorchJob을 쓰나?** 분산 학습은 여러 Pod(worker)가 서로 통신하며 GPU를 나눠 써야 하는데, 이걸 손으로 관리하기 어렵습니다. **Kubeflow Training Operator**에게 `PyTorchJob`(설정서)을 주면 worker Pod 생성·네트워크 연결(rendezvous)·재시작을 자동으로 처리합니다.
→ 이 클러스터에는 `pytorchjobs.kubeflow.org` CRD와 그것을 처리하는 operator(`kubeflow` 네임스페이스)가 이미 설치돼 있습니다.

### 3️⃣ 학습 모니터링 — `3.monitor_training.sh`

**왜 따로?** 학습은 수 분~수 시간 걸리므로, Job 상태(Running/Succeeded/Failed)와 실시간 로그(loss 감소 등)를 확인할 수단이 필요합니다.

### 4️⃣ 리소스 정리 — `4.cleanup.sh`

**왜?** 학습이 끝난 Pod도 GPU 슬롯을 점유할 수 있어, 다음 작업(다른 학습/추론)을 위해 정리합니다.

### 🔁 한눈에 보는 흐름

```
[1] 클러스터 접근 권한       →  kubectl 사용 가능
        ↓
[2] PyTorchJob 배포          →  operator가 worker Pod들을 GPU 노드에 분산 배치
        ↓
   (컨테이너 안에서) 의존성 설치 → 모델·데이터 다운로드 → LoRA 학습
        ↓
[3] 모니터링                 →  loss 감소·Job 상태 확인
        ↓
[4] 정리                     →  PyTorchJob 삭제, GPU 슬롯 반환
```

</details>

## 사전 요구사항

- HyperPod EKS 클러스터가 생성되어 있어야 함
- **GPU 노드 2개 이상** (worker 2개 × GPU 1개 = GPU 2개 사용)
- **Kubeflow Training Operator** (HyperPod 기본 제공, `kubeflow` 네임스페이스)
- **NVIDIA Device Plugin** (HyperPod 기본 제공)
- `eks/setup` 폴더의 환경 설정을 먼저 완료 (아래 Step 0)

---

## 📋 전체 실습 순서

```
eks/setup/                              eks/training/
├── 1.create-config-workshop.sh   →     ├── 1.grant_eks_access.sh
├── 2.setup-eks-access.sh               ├── 2.run_training.sh
└── 3.validate-cluster.sh               ├── 3.monitor_training.sh
                                        └── 4.cleanup.sh
```

### Step 0: 환경 설정 (최초 1회)

```bash
cd ../setup
./1.create-config-workshop.sh   # env_vars 생성
./2.setup-eks-access.sh         # EKS 접근 권한
./3.validate-cluster.sh         # 클러스터 검증
cd ../training
```

> **Note**: `1.create-config-workshop.sh`가 만드는 `env_vars` 파일은 이후 스크립트에서 자동 로드됩니다.

---

## 📂 스크립트 설명

| 스크립트 | 역할 | 비고 |
|---|---|---|
| `1.grant_eks_access.sh` | 현재 사용자에게 **EKS 접근 권한**(Access Entry + Admin Policy) 부여 후 kubeconfig 갱신. GPU 노드·필수 컴포넌트도 점검. | 항상 먼저 1회 |
| `2.run_training.sh` | `template/pytorchjob_finetuning.yaml`을 배포해 **PyTorchJob 학습 시작**. 기존 잡이 있으면 정리 여부를 묻고, Pod 생성 상태를 모니터링. | 학습 실행 |
| `3.monitor_training.sh` | PyTorchJob/Pod 상태와 **실시간 학습 로그**(loss 등)를 출력. Succeeded/Failed에 따라 결과/에러 로그 표시. | 진행 확인 |
| `4.cleanup.sh` | PyTorchJob과 관련 Pod 삭제 (확인 프롬프트). | 정리 |
| `template/pytorchjob_finetuning.yaml` | 학습 정의서. 컨테이너 이미지, **LoRA 학습 스크립트**(인라인 Python), worker 수, GPU/CPU/메모리 요청을 포함. | 핵심 설정 |

---

## 🚀 빠른 시작 (자동화 스크립트)

### 1. 클러스터 접근 설정

```bash
./1.grant_eks_access.sh
```
- `../setup/env_vars`에서 환경 변수 자동 로드, 클러스터 자동 감지
- Access Entry 생성·권한 부여, kubeconfig 설정, GPU 노드 확인
- 직접 지정: `./1.grant_eks_access.sh [CLUSTER_NAME] [REGION]`

### 2. Fine-tuning 실행

```bash
./2.run_training.sh
```
- PyTorchJob 배포 → worker Pod 2개 생성 → 상태 모니터링
- 첫 실행은 이미지(~10GB) 다운로드로 **5~10분** 걸릴 수 있습니다.

### 3. 학습 모니터링

```bash
./3.monitor_training.sh
```

### 4. 리소스 정리

```bash
./4.cleanup.sh
```

---

## 📖 상세 가이드 (수동 Step-by-Step)

자동화 스크립트 대신 각 단계를 수동으로 실행하려면 아래를 따르세요.

### Step 1: EKS 클러스터 접속 설정

```bash
aws eks update-kubeconfig --name "YOUR_EKS_CLUSTER_NAME" --region us-west-2
kubectl get nodes
```

### Step 2: GPU 노드 확인

```bash
kubectl get nodes -o custom-columns="NAME:.metadata.name,INSTANCE-TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,GPU:.status.capacity.nvidia\.com/gpu"
```

출력 예시:
```
NAME                           INSTANCE-TYPE   GPU
hyperpod-i-011c42934cdb720f9   ml.g5.2xlarge   1
hyperpod-i-03f9d334b8c0c63bf   ml.g5.2xlarge   1
```

### Step 3: 필수 구성요소 확인

```bash
# Training Operator (PyTorchJob을 처리하는 컨트롤러)
kubectl get pods -n kubeflow

# NVIDIA Device Plugin
kubectl get pods -n kube-system | grep nvidia

# PyTorchJob CRD가 등록돼 있는지
kubectl get crd pytorchjobs.kubeflow.org
```

### Step 4: PyTorchJob 배포

```bash
# 먼저 스키마 검증(선택) — 실제로 만들지 않고 확인
kubectl apply -f template/pytorchjob_finetuning.yaml --dry-run=server

# 배포
kubectl apply -f template/pytorchjob_finetuning.yaml
```

> **Note**: FSx 없이 동작합니다. 모델·데이터는 HuggingFace에서 직접 다운로드됩니다.

### Step 5: Pod 상태 확인

```bash
kubectl get pods -l training.kubeflow.org/job-name=deepseek-finetuning
kubectl describe pod deepseek-finetuning-worker-0   # 이미지 pull 등 이벤트
```

출력 예시:
```
NAME                           READY   STATUS    RESTARTS   AGE
deepseek-finetuning-worker-0   1/1     Running   0          2m
deepseek-finetuning-worker-1   1/1     Running   0          2m
```

### Step 6: 학습 로그 확인

```bash
kubectl logs -f deepseek-finetuning-worker-0
```

출력 예시 (loss가 감소하면 정상):
```
trainable params: 4,358,144 || all params: 1,781,446,144 || trainable%: 0.2446
Starting training...
{'loss': 6.5339, 'learning_rate': 4e-05, 'epoch': 0.09}
{'loss': 0.4105, 'learning_rate': 0.00016, 'epoch': 0.36}
...
{'train_loss': 1.2063, 'epoch': 1.0}
Training completed!
```

### Step 7: PyTorchJob 상태 확인

```bash
kubectl get pytorchjob deepseek-finetuning
```

출력 예시:
```
NAME                  STATE       AGE
deepseek-finetuning   Succeeded   4m
```

### Step 8: 리소스 정리

```bash
kubectl delete pytorchjob deepseek-finetuning
```

---

## 📊 학습 설정 커스터마이징

`template/pytorchjob_finetuning.yaml`을 수정합니다.

### Worker 수 / 노드당 GPU

```yaml
spec:
  nprocPerNode: "1"        # 노드당 GPU(프로세스) 수
  pytorchReplicaSpecs:
    Worker:
      replicas: 2          # worker Pod 수 (= 필요 GPU 수)
```

> ⚠️ `replicas`는 **사용 가능한 GPU 수 이하**여야 합니다. GPU가 1개뿐이면 `replicas: 1`로 줄이세요. 안 그러면 일부 worker가 GPU 부족으로 Pending됩니다.

### 리소스 요청 (인스턴스 크기에 맞추기)

```yaml
resources:
  requests:
    cpu: "6"        # ⚠️ 노드 allocatable보다 작게! g5.2xlarge는 ~7.9 vCPU
    memory: "24Gi"  # ⚠️ g5.2xlarge allocatable ~29Gi
    nvidia.com/gpu: 1
```

> ⚠️ **중요**: `cpu`/`memory` 요청이 노드 **allocatable**(물리량 − 시스템예약)보다 크면 Pod가 **영원히 Pending**됩니다. g5.2xlarge(8 vCPU/32Gi)는 allocatable이 ~7.9 vCPU / ~29Gi이므로 `cpu:"8"`·`memory:"32Gi"`는 들어가지 않습니다. 더 큰 인스턴스면 비례해서 올리세요.

### LoRA / 하이퍼파라미터

```python
lora_config = LoraConfig(r=16, lora_alpha=32, lora_dropout=0.05,
    target_modules=["q_proj","k_proj","v_proj","o_proj"])

training_args = TrainingArguments(
    num_train_epochs=1, per_device_train_batch_size=2,
    gradient_accumulation_steps=4, learning_rate=2e-4, warmup_steps=50)
```

---

## 🔧 트러블슈팅

이 가이드는 실제 클러스터에서 실행·검증되었습니다. 자주 만나는 문제와 해결법입니다.

### 1. `kubectl`이 `Unauthorized` / 토큰 만료

```
error: You must be logged in to the server (Unauthorized)
ExpiredToken: The security token included in the request is expired
```
**원인:** 워크샵 임시 자격증명(STS)은 수명이 짧아 만료됩니다.
**해결:** 자격증명을 갱신(워크샵 콘솔에서 재발급)한 뒤 `./1.grant_eks_access.sh` 재실행.

### 2. Pod가 계속 `Pending` (스케줄 불가)

```
FailedScheduling: 0/2 nodes are available: Insufficient cpu, Insufficient memory
(또는 Insufficient nvidia.com/gpu)
```
**원인 A — 리소스 요청 과다:** `cpu`/`memory` 요청이 노드 **allocatable**보다 큼. (템플릿 기본값은 g5.2xlarge에 맞춰 `cpu:6/memory:24Gi`)
```bash
# 노드 여유 확인
kubectl describe node <node> | sed -n '/Allocated resources:/,/Events:/p'
```
**원인 B — GPU 부족:** 다른 워크로드가 GPU를 점유 중이거나 `replicas`가 GPU 수보다 많음.
```bash
# GPU 점유 현황
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
# → replicas를 가용 GPU 수에 맞추거나, GPU 쓰는 다른 Pod를 정리
```

### 3. `CrashLoopBackOff` — 컨테이너가 시작 후 죽음 (라이브러리 버전 충돌)

```
ModuleNotFoundError: No module named 'transformers.conversion_mapping'
```
**원인:** 이미지에 들어있는 `transformers`는 구버전인데, 버전을 고정하지 않은 `pip install peft`가 **최신 peft**를 받아 둘이 충돌합니다(최신 peft가 신버전 transformers 모듈을 요구).
**해결:** 템플릿의 `pip install`에서 **버전을 핀 고정**합니다 (현재 템플릿에 적용됨):
```bash
pip install --quiet \
  "transformers==4.49.0" "peft==0.14.0" "accelerate==1.4.0" \
  "datasets==3.3.2" "trl==0.15.2" "bitsandbytes==0.45.3"
```
```bash
# 크래시 원인은 직전 로그에서 확인
kubectl logs deepseek-finetuning-worker-0 --previous
```

### 4. 이미지 다운로드가 느림

`huggingface/transformers-pytorch-gpu:latest`는 약 10GB라 첫 실행 시 5~10분 소요됩니다. (한 번 받으면 노드에 캐시됨)
```bash
kubectl describe pod deepseek-finetuning-worker-0 | grep -A5 "Events:"
```

### 5. OOM (Out of Memory)

배치 크기·시퀀스 길이를 줄이세요 (학습 스크립트 내):
```python
per_device_train_batch_size=1   # 2 → 1
max_length=256                  # 512 → 256
```

---

## 📋 유용한 명령어

```bash
# 모든 리소스 상태
kubectl get pods,pytorchjob

# 실시간 로그
kubectl logs -f deepseek-finetuning-worker-0

# 모든 워커 로그
for i in 0 1; do echo "=== Worker $i ==="; kubectl logs deepseek-finetuning-worker-$i --tail=20; done

# GPU 사용량
kubectl exec deepseek-finetuning-worker-0 -- nvidia-smi

# PyTorchJob 상세
kubectl describe pytorchjob deepseek-finetuning
```

---

## 📚 참고 정보

### 학습 구성 (검증된 값)

| 항목 | 값 |
|------|-----|
| 모델 | DeepSeek-R1-Distill-Qwen-1.5B |
| 학습 방법 | LoRA (r=16, alpha=32) |
| 데이터셋 | Alpaca (1000 샘플) |
| Trainable Parameters | 약 4.3M (0.24%) |
| Worker / GPU | 2 worker × GPU 1 |
| 실측 학습 시간 | 약 2분 (`train_runtime` ~125초) |
| 핀 고정 버전 | transformers 4.49.0 / peft 0.14.0 / accelerate 1.4.0 |

### 스토리지

FSx 없이 동작합니다:
- 모델·데이터: HuggingFace에서 직접 다운로드
- 출력: `emptyDir` (**Pod 종료 시 삭제**)

> **주의**: 학습 결과를 영구 저장하려면 아래 "복원력" 섹션처럼 FSx/EBS를 마운트하세요.

### 참고 문서
- [Kubeflow Training Operator](https://github.com/kubeflow/training-operator)
- [PEFT](https://github.com/huggingface/peft)
- [DeepSeek-R1 모델](https://huggingface.co/deepseek-ai)
- [SageMaker HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)

---

## 🔄 고급: Auto Restart 및 복원력 (Resiliency)

대규모 분산 학습에서는 하드웨어 장애·네트워크 문제로 학습이 중단될 수 있습니다. HyperPod EKS에서 활용할 수 있는 복원력 기능입니다.

### 1. restartPolicy

```yaml
spec:
  pytorchReplicaSpecs:
    Worker:
      replicas: 2
      restartPolicy: OnFailure    # 실패 시 자동 재시작 (현재 템플릿 기본값)
```

| 옵션 | 설명 |
|------|------|
| `OnFailure` | Pod 실패 시에만 재시작 (학습 권장) |
| `Always` | 항상 재시작 (서비스용) |
| `Never` | 재시작 안 함 (디버깅·일회성) |

### 2. Checkpoint 기반 재개 (영구 스토리지 필요)

`emptyDir`는 Pod 종료 시 사라지므로, checkpoint를 남기려면 **FSx/EBS**를 마운트해야 합니다.

```yaml
volumes:
  - name: checkpoint-storage
    persistentVolumeClaim:
      claimName: fsx-claim
# containers[].volumeMounts:
#   - name: checkpoint-storage
#     mountPath: /checkpoint
```
```python
training_args = TrainingArguments(
    output_dir="/checkpoint/deepseek-finetuning",
    save_steps=100, save_total_limit=3)
trainer.train(resume_from_checkpoint=True)
```

### 3. HyperPod 자동 노드 복구

- **Deep Health Checks**: GPU/Trainium 인스턴스 심층 헬스 체크
- **자동 노드 교체**: 하드웨어 장애 감지 시 자동 교체
```bash
kubectl get pods -n aws-hyperpod | grep health-monitoring
```

### 4. Elastic Training

일부 worker가 실패해도 학습을 계속:
```yaml
spec:
  elasticPolicy:
    minReplicas: 1
    maxReplicas: 4
    rdzvBackend: c10d
    maxRestarts: 3
```

### 복원력 체크리스트

| 항목 | 설정 | 기본 |
|------|------|------|
| restartPolicy | `OnFailure` | ✅ |
| Checkpoint | 영구 스토리지에 저장 | ⬜ (emptyDir라 미적용) |
| resume_from_checkpoint | 학습 코드에 추가 | ⬜ |
| elasticPolicy | 필요시 설정 | ⬜ |
| Health Monitoring | HyperPod 기본 제공 | ✅ |
