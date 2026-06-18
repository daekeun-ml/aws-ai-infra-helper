# HyperPod Inference Endpoint 배포 및 테스트 가이드

<details>
<summary>📖 <b>처음이신가요? 기본 용어 먼저 보기 (클릭해서 펼치기)</b></summary>

<br>

이 가이드에 자주 나오는 용어들을 쉽게 정리했습니다. 이미 익숙하다면 건너뛰어도 됩니다.

### 인프라 / 쿠버네티스 기본

| 용어 | 쉬운 설명 |
|---|---|
| **EKS** (Elastic Kubernetes Service) | AWS가 관리해 주는 **쿠버네티스(Kubernetes)** 클러스터. 컨테이너(앱)를 여러 서버에 띄우고 관리하는 시스템입니다. |
| **HyperPod** | SageMaker의 대규모 ML 학습·추론용 인프라. 여기서는 **EKS 기반 HyperPod** 클러스터를 사용합니다. |
| **노드(Node)** | 실제 작업이 도는 서버(EC2 인스턴스) 1대. 예: `ml.g5.2xlarge`(GPU 1개 달린 서버). |
| **Pod** | 쿠버네티스에서 컨테이너를 실행하는 **가장 작은 단위**. 보통 "앱 1개 = Pod 1개"로 생각하면 됩니다. |
| **Deployment** | Pod를 몇 개 띄울지·어떻게 유지할지 정의하는 리소스. Pod가 죽으면 자동으로 다시 띄웁니다. |
| **Service** | 여러 Pod에 **안정적인 주소(이름)**를 주는 리소스. Pod IP는 재시작 시 바뀌지만 Service 이름은 그대로입니다. |
| **DaemonSet** | **모든 노드마다 하나씩** 띄우는 Pod (예: GPU 드라이버, 스토리지 드라이버). |
| **kubectl** | 쿠버네티스를 조작하는 명령줄 도구. (`kubectl get pods` = Pod 목록 보기) |
| **kubeconfig** | 내 PC가 어느 클러스터에 어떻게 접속할지 적힌 설정 파일. |

### 스토리지 / 모델

| 용어 | 쉬운 설명 |
|---|---|
| **S3** | AWS의 오브젝트 스토리지(파일 저장소). 여기서는 **모델 가중치**를 보관합니다. |
| **FSx for Lustre** | 고성능 공유 파일시스템. S3보다 빠른 파일 접근이 필요할 때 모델을 올려 둡니다. |
| **CSI 드라이버** (Container Storage Interface) | Pod가 S3·FSx 같은 외부 스토리지를 **디스크처럼 마운트**할 수 있게 해주는 플러그인. |
| **PV / PVC** (PersistentVolume / Claim) | PV는 "실제 저장공간", PVC는 "그 저장공간을 쓰겠다는 신청서". Pod는 PVC를 통해 볼륨을 씁니다. |

### 권한 / 인증

| 용어 | 쉬운 설명 |
|---|---|
| **IAM Role** | AWS 리소스(S3 등)에 접근할 권한 묶음. 사용자나 서버에 부여합니다. |
| **IRSA** (IAM Roles for Service Accounts) | **쿠버네티스 서비스어카운트**에 IAM Role을 연결하는 방식. OIDC를 사용하며, Pod 단위로 **권한을 좁게** 줄 수 있어 안전합니다. |
| **Pod Identity** | IRSA와 비슷하게 Pod에 IAM 권한을 주는 더 최신 방식 (OIDC 설정 없이 더 간단). |
| **임시 자격증명(STS)** | 워크샵 환경에서 주는 **수명이 짧은** 키. 액세스 키가 `ASIA...`로 시작하며 **`session_token`이 반드시 함께** 필요합니다. (영구 키는 `AKIA...`) |

### 추론 / 모델 서빙

| 용어 | 쉬운 설명 |
|---|---|
| **Inference Endpoint** | 학습된 모델을 **API로 호출**할 수 있게 띄운 추론 서버. |
| **InferenceEndpointConfig** | HyperPod **inference operator**가 읽는 커스텀 리소스(CRD). 이걸 만들면 operator가 추론 서버 배포를 알아서 구성합니다. |
| **Operator** | 특정 리소스(CRD)를 감시하다가 자동으로 배포·관리해 주는 쿠버네티스 컨트롤러. |
| **CRD** (Custom Resource Definition) | 쿠버네티스에 **새로운 리소스 종류**를 추가하는 확장. `InferenceEndpointConfig`가 그 예입니다. |
| **vLLM / TGI / DJL** | LLM을 빠르게 서빙하는 추론 엔진/서버. 컨테이너 이미지 안에 들어 있습니다. |
| **GPU 슬롯 / maxPods** | 노드 1대가 받을 수 있는 Pod 개수 한도. 작은 인스턴스는 이 한도가 낮아 배포가 막힐 수 있습니다. |

</details>

<details>
<summary>🤔 <b>이 절차는 왜 필요한가? (전체 흐름과 각 단계의 이유)</b></summary>

<br>

스크립트를 그냥 따라 하기 전에, **무엇을 하려는 것이고 왜 이런 단계들이 필요한지** 이해하면 문제가 생겼을 때 훨씬 쉽게 해결할 수 있습니다.

### 🎯 최종 목표

> **S3나 FSx에 저장된 LLM 모델 가중치를, GPU가 달린 Pod에 올려서 "API로 호출 가능한 추론 서버"로 띄우는 것.**

이 목표를 이루려면 아래 5가지가 순서대로 갖춰져야 합니다. 각 스크립트는 이 중 하나씩을 담당합니다.

### 1️⃣ 클러스터에 접근할 권한 — `1.grant_eks_access.sh`

**왜?** EKS 클러스터는 보안상 **만든 사람 외에는 `kubectl` 접근을 기본 차단**합니다. 그래서 내 IAM 신원(사용자/역할)을 클러스터의 **Access Entry**로 등록하고 관리자 정책을 연결해야 `kubectl get nodes`조차 동작합니다.
→ 이걸 안 하면: `error: You must be logged in to the server (Unauthorized)`

### 2️⃣ 모델을 외부 스토리지에 보관 — `3.copy_to_s3.sh` 또는 `2.prepare_fsx_inference.sh`

**왜 모델을 컨테이너 이미지에 안 넣고 따로 두나?** LLM 가중치는 수 GB~수십 GB로 **너무 커서** 컨테이너 이미지에 넣으면 이미지가 비대해지고 빌드·배포가 느려집니다. 그래서 모델은 **S3(오브젝트 스토리지)나 FSx(고성능 파일시스템)** 에 두고, Pod가 시작될 때 **마운트하거나 다운로드**합니다.
- **S3**: 저렴하고 간단. 시작 시 다운로드(또는 스트리밍).
- **FSx for Lustre**: S3보다 빠른 파일 접근. 모델을 자주/빠르게 읽어야 할 때.

### 3️⃣ Pod가 그 스토리지를 읽을 수 있게 — `4.addon_s3_csi.sh` / `4.fix_s3_csi_credentials.sh`

**왜 별도 단계가?** Pod가 S3/FSx를 **로컬 디스크처럼 마운트**하려면 두 가지가 필요합니다:
1. **CSI 드라이버**(스토리지 플러그인)가 클러스터에 설치되어 있어야 하고,
2. 그 드라이버가 S3에 접근할 **AWS 권한**이 있어야 합니다.

권한을 주는 방식이 환경에 따라 다릅니다:
- **`4.fix_s3_csi_credentials.sh`** → **IRSA(OIDC)** 방식. 서비스어카운트에 좁은 권한의 IAM Role 연결 (정식 계정·안전).
- **`4.addon_s3_csi.sh`** → **Pod Identity** 방식. 더 간단한 최신 권한 연결.

→ 이 권한이 없으면: `InvalidAccessKeyId`, `No signing credentials`, 또는 마운트 실패로 Pod가 `ContainerCreating`에서 멈춤.

### 4️⃣ 추론 서버 배포 — Operator (`2` FSx / `5a` S3) 또는 Direct (`5b` S3)

**왜 두 가지 방식?** "누가 배포를 관리하느냐"의 차이입니다.
- **🅰️ Operator(`2` FSx, `5a` S3)**: `InferenceEndpointConfig`라는 **설정서(CRD)** 하나만 제출하면, HyperPod **operator**가 Deployment·Service·오토스케일링·TLS를 알아서 만들어 줍니다. (자동화 ↑, 단 operator가 살아 있어야 함)
- **🅱️ Direct(`5b` S3)**: operator 없이 **표준 Deployment/Service/PV/PVC를 직접** 정의. operator가 고장나도 동작하고 권한 설정도 단순.

→ 자세한 비교는 아래 [배포 방식 비교](#-배포-방식-비교) 표 참고.

### 5️⃣ 엔드포인트 호출(테스트) — `6a.create_test_pod.sh`

**왜 클러스터 "안에서" 호출하나?** 추론 Service가 **`ClusterIP` 타입**이라 클러스터 **내부에서만** 접근 가능하기 때문입니다. 외부 IP가 없고(`EXTERNAL-IP <none>`), `*.svc.cluster.local` 주소도 클러스터 내부 DNS만 풀 수 있어서, 내 노트북에서는 그 주소로 바로 호출되지 않습니다. 따라서 호출하려면 둘 중 하나가 필요합니다:

- **① 클러스터 안의 Pod에서 호출** — `6a.create_test_pod.sh`가 띄우는 `test-endpoint` Pod에 `kubectl exec`로 들어가 실행. (`kubectl exec test-endpoint -- ...` 명령은 *이미 떠 있는* 그 Pod 안에서 도는 것입니다.)
- **② `kubectl port-forward`로 외부에 임시 노출** — 테스트 Pod 없이 내 노트북에서 바로 호출:
  ```bash
  kubectl port-forward svc/deepseek15b-fsx-routing-service 8443:443
  # 다른 터미널에서:
  curl http://localhost:8443/invocations \
    -H 'Content-Type: application/json' \
    -d '{"inputs": "Hi, what can you help me with?"}'
  ```

> 즉 테스트 Pod는 **유일한 방법이 아니라 가장 간단한 방법 중 하나**입니다. (영구 외부 노출이 필요하면 Service를 LoadBalancer/NodePort로 바꾸거나 Ingress/ALB를 붙입니다.)
> 호출 시 자주 막히는 부분(포트 443=HTTP, requests 모듈, Service명 사용)은 아래 [트러블슈팅](#트러블슈팅) 참고.

### 🔁 한눈에 보는 흐름

```
[1] 클러스터 접근 권한      →  kubectl 사용 가능
        ↓
[2] 모델을 S3/FSx에 보관    →  큰 가중치를 이미지 밖에 저장
        ↓
[3] CSI 드라이버 + 권한      →  Pod가 스토리지를 마운트/다운로드
        ↓
[4] 추론 서버 배포          →  GPU Pod에 모델 올려 서빙 (Operator or Direct)
        ↓
[5] 테스트 Pod에서 호출      →  /invocations 로 추론 결과 확인
```

</details>

## 🚀 빠른 시작 (자동화 스크립트)

### 1. 클러스터 접근 설정 (../../setup/1.create-config.sh 실행 후 생성되는 env_var의 환경 변수를 로드합니다.)
```bash
./1.grant_eks_access.sh
```

### 2. 배포 방법 선택

> **계정 종류(정식 AWS vs 워크샵 임시)로 갈리는 게 아닙니다.** 세 방식 모두 양쪽 계정에서 동작합니다.
> 실제 차이는 **저장소(FSx vs S3)** 와 **배포 주체(Operator vs Direct)** 입니다 — 아래 [방식 비교](#-배포-방식-비교) 참고.

#### 방식 A — FSx 기반 (Operator)
```bash
# FSx 환경 준비 (자격증명은 AWS 프로파일에서 읽어 copy job에 주입)
./2.prepare_fsx_inference.sh

# FSx로 모델 복사
kubectl apply -f copy_to_fsx_lustre.yaml

# 추론 엔드포인트 배포
kubectl apply -f deploy_fsx_lustre_inference_operator.yaml
```

#### 방식 B — S3 기반 (Operator)
```bash
# S3 환경 준비
./3.copy_to_s3.sh
./4.fix_s3_csi_credentials.sh
./5a.prepare_s3_inference_operator.sh

# 추론 엔드포인트 배포
kubectl apply -f deploy_S3_inference_operator.yaml
```

#### 방식 C — S3 기반 (Direct)
```bash
# S3 환경 준비
./3.copy_to_s3.sh
./5b.prepare_s3_direct_deploy.sh

# 추론 엔드포인트 배포
kubectl apply -f deploy_S3_direct.yaml
```

#### 📌 배포 방식 비교

세 방식 모두 **정식 AWS 계정·워크샵 임시 계정 양쪽에서 동작**합니다. 차이는 *계정 종류*가 아니라 **저장소(FSx vs S3)** 와 **배포 주체(Operator vs Direct)**, 그리고 **권한을 얻는 방식**입니다.

| 구분 | A. FSx (Operator) `2` | B. S3 (Operator) `5a` | C. S3 (Direct) `5b` |
|---|---|---|---|
| **저장소** | FSx for Lustre | S3 | S3 |
| **배포 주체** | inference operator (CRD) | inference operator (CRD) | 표준 Deployment 직접 |
| **operator 의존** | 필요 | 필요 | **불필요** (고장나도 동작) |
| **Service 이름·포트** | `…-fsx-routing-service` : 443 | `…-routing-service` : 443 | `deepseek15b` : 8080 |
| **권한 방식** | copy job에 프로파일 키 주입 | **IRSA** (OIDC, 좁은 권한) | **노드 IAM Role에 S3FullAccess** (넓음) |
| **언제** | 빠른 파일 접근/공유 스토리지 필요 | 정석·안전한 S3 서빙 | operator 없이 빠르고 간편하게 |

**한 줄 요약**
- **A. FSx** — 고성능 공유 파일시스템에서 서빙. (모델을 FSx에 두고 빠르게 로드)
- **B. S3 + Operator** — "정석" S3 서빙. operator가 관리, IRSA로 권한을 좁게.
- **C. S3 + Direct** — operator 없이 표준 리소스 직접. 가장 간단하지만 노드에 S3 풀권한(느슨).

> 💡 셋 다 워크샵에서도 정식 계정에서도 됩니다. 권한 설정 난이도만 다릅니다(Direct가 가장 단순).

> 💡 `kubectl apply` 시 `conversion webhook ... no endpoints available` 에러는 **🅰️ Operator 경로에서만** 발생합니다 (operator가 필수라서). 🅱️ Direct는 operator를 쓰지 않으므로 이 문제가 없습니다 — 워크샵에서 🅱️를 권하는 이유 중 하나입니다. (해결법은 아래 [트러블슈팅](#트러블슈팅) 참고)

### ⚠️ 리소스 부족 문제 해결

`ml.g5.2xlarge` 등 작은 인스턴스를 사용하거나 노드에 Pod가 많아서 배포가 실패하는 경우:

```bash
kubectl get pods -w

# NAME                          READY   STATUS    RESTARTS   AGE
# deepseek15b-59586756d-h7vsx   0/1     Pending   0          30s
```

```bash
# 문제 해결 스크립트 실행 (노드 maxPods 상향으로 슬롯 확보)
cd ../../setup
./4.ensure-workshop-capacity.sh
cd -

# 기존 배포 삭제 후 재배포
kubectl delete deployment deepseek15b
kubectl apply -f deploy_S3_direct.yaml
```

## 📊 테스트 

> ⚠️ **배포 방식에 따라 Service 이름·포트가 다릅니다** (헷갈리기 쉬움):
> | 방식 | Deployment | Service | 포트 |
> |---|---|---|---|
> | **S3 Direct** (`5b`) | `deepseek15b` | `deepseek15b` | **8080** (HTTP) |
> | **FSx / S3 Operator** (`2`/`5a`) | `deepseek15b-fsx` | `deepseek15b-fsx**-routing-service**` | **443** (평문 HTTP) |
>
> Operator 방식은 Service에 `-routing-service` 접미사가 붙고 포트가 443입니다. (`https://`가 아니라 `http://...:443`)

#### S3 Direct 방식 (`5b` → `deepseek15b`)

```bash
# Pod 상태 확인
kubectl get pods -w

# 로그 확인 (모델 로딩 진행 상황)
kubectl logs -l app=deepseek15b -f

# Service 확인
kubectl get svc deepseek15b

# 간단한 테스트 (Pod에 직접 exec)
kubectl exec -it deployment/deepseek15b -- curl -X POST http://localhost:8080/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": "Explain machine learning in simple terms.", "parameters": {"max_new_tokens": 200, "temperature": 0.7, "repetition_penalty": 1.5}}'

# 테스트용 Pod 띄워서 Service 이름으로 호출
kubectl run test-curl --rm -i --restart=Never --image=curlimages/curl -- \
  curl -X POST http://deepseek15b:8080/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": "Explain machine learning in simple terms.", "parameters": {"max_new_tokens": 200, "temperature": 0.7, "repetition_penalty": 1.5}}'
```

#### FSx / S3 Operator 방식 (`2`/`5a` → `deepseek15b-fsx`)

Operator가 만든 Deployment 이름은 `deepseek15b-fsx`지만, **Service는 `deepseek15b-fsx-routing-service`(포트 443)** 입니다.

```bash
# Pod 상태 확인
kubectl get pods -l app=deepseek15b-fsx -w

# 로그 확인 (여러 컨테이너 중 추론 컨테이너 지정)
kubectl logs -l app=deepseek15b-fsx -c deepseek15b-fsx -f

# Service 확인 (이름이 -routing-service!)
kubectl get svc deepseek15b-fsx-routing-service

# 간단한 테스트 (Pod에 직접 exec — 추론 컨테이너의 8080)
kubectl exec -it deployment/deepseek15b-fsx -c deepseek15b-fsx -- curl -X POST http://localhost:8080/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": "Explain machine learning in simple terms.", "parameters": {"max_new_tokens": 200, "temperature": 0.7, "repetition_penalty": 1.5}}'

# 테스트용 Pod 띄워서 Service 이름으로 호출 (포트 443, http:// 사용 — https 아님!)
kubectl run test-curl --rm -i --restart=Never --image=curlimages/curl -- \
  curl -X POST http://deepseek15b-fsx-routing-service:443/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": "Explain machine learning in simple terms.", "parameters": {"max_new_tokens": 200, "temperature": 0.7, "repetition_penalty": 1.5}}'
```

### AWS 계정
배포 완료 후 추론 엔드포인트를 테스트할 수 있습니다:

```bash
# 기본 추론 테스트 (invoke.py에서 ENDPOINT_NAME 수정 필요)
python invoke.py
```

> **참고**: `invoke.py` 파일에서 `ENDPOINT_NAME`을 배포한 엔드포인트 이름으로 수정하세요.
> - FSx 배포: `'deepseek15b-fsx'`
> - S3 배포: `'deepseek15b'` (또는 사용자 정의 이름)

---

## 📂 스크립트 설명

각 샘플 스크립트가 무엇을 하는지 요약입니다. 번호는 실행 순서를 뜻하며, 같은 번호(`4`, `5a`/`5b`)는 **상황에 따라 택일**합니다.

| 스크립트 | 역할 | 언제 쓰나 |
|---|---|---|
| `1.grant_eks_access.sh` | 현재 사용자에게 **EKS 클러스터 접근 권한** 부여 (Access Entry + Admin Policy) 후 kubeconfig 갱신. `env_vars`에서 클러스터명 자동 로드, 없으면 자동 감지. | **항상 먼저** 1회 |
| `2.prepare_fsx_inference.sh` | **FSx 경로** 준비. AWS 프로파일에서 자격증명을 읽어 모델 복사 Job YAML(`copy_to_fsx_lustre.yaml`)과 추론 배포 YAML을 생성. 인스턴스 타입을 감지해 cpu/memory 요청을 자동 조정. | FSx 기반 배포 시 |
| `3.copy_to_s3.sh` | **S3 경로** 준비. S3 버킷을 만들고(없으면) JumpStart 캐시에서 **모델을 내 S3 버킷으로 복사**. `S3_BUCKET_NAME`을 설정. | S3 기반 배포 시 (🅰️·🅱️ 공통) |
| `4.addon_s3_csi.sh` | **S3 CSI 드라이버를 Pod Identity 방식으로 설치**. Pod Identity Agent 애드온 + IAM Role(S3FullAccess) + Pod Identity Association 구성. (`4.fix...`의 대안 설치 경로) | S3 CSI가 아예 없을 때 |
| `4.fix_s3_csi_credentials.sh` | **S3 CSI 드라이버 자격증명 문제 해결**. CSI 드라이버 상태 점검 후 필요 시 재설치하고, **IRSA(OIDC)** 기반 IAM Role을 만들어 `s3-csi-driver-sa`에 연결. | 🅰️ Operator 경로 (정식 계정) |
| `5a.prepare_s3_inference_operator.sh` | 🅰️ **Operator 방식** 배포 YAML(`deploy_S3_inference_operator.yaml`) 생성. `InferenceEndpointConfig`(CRD)를 만들어 operator가 배포를 관리. 인스턴스 타입/버킷/리전 자동 치환. | 🅰️ 정식 계정 |
| `5b.prepare_s3_direct_deploy.sh` | 🅱️ **Direct 방식** 배포 YAML(`deploy_S3_direct.yaml`) 생성. 표준 Deployment+Service+PV/PVC를 직접 정의하고, **노드 IAM Role에 S3FullAccess**를 붙여 operator 없이 배포. | 🅱️ 워크샵 임시 계정 |
| `6a.create_test_pod.sh` | **테스트용 Pod**(`test-endpoint`, python:3.11-slim + requests) 생성 후, 배포된 추론 엔드포인트 목록을 보여주고 호출 명령을 안내. | 배포 후 테스트 시 |

> **🅰️ Operator vs 🅱️ Direct 차이**는 위 [배포 방식 비교](#-배포-방식-비교) 표를 참고하세요.
> 두 `4.*` 스크립트는 **S3 CSI 권한을 얻는 방식이 다릅니다**: `4.addon_s3_csi.sh`는 **Pod Identity**, `4.fix_s3_csi_credentials.sh`는 **IRSA(OIDC)** 기반입니다.

---

## 📖 상세 가이드 (수동 Step-by-Step)

자동화 스크립트 대신 각 단계를 수동으로 이해하고 실행하려면 아래 가이드를 따르세요.

### 사전 준비

### 0. EKS 클러스터 생성

HyperPod에서 EKS 기반 클러스터 생성하는 [가이드라인](https://docs.aws.amazon.com/ko_kr/sagemaker/latest/dg/sagemaker-hyperpod-eks-operate-console-ui-create-cluster.html
)을 참고하여 EKS 클러스터를 생성합니다.

### 1. EKS 클러스터 접속 설정

```bash
# HyperPod EKS 클러스터에 kubeconfig 설정 (Console에서 클러스터 클릭 후 Orchestrator 항목에서 이름 확인 가능)
aws eks update-kubeconfig --name "YOUR_EKS_CLUSTER_NAME" --region us-west-2

# 클러스터 연결 확인
kubectl get nodes
```

### 2. PVC 상태 확인

```bash
kubectl get pvc
```

출력 예시:
```
NAME        STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
fsx-claim   Bound    fsx-pv   1200Gi     RWX            fsx-sc
```

---

## 방법 1: FSX Lustre 기반 Endpoint 배포

### Step 1: 모델을 FSX로 복사

**copy.yaml 파일 생성:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: copy-model-to-fsx
spec:
  template:
    spec:
      containers:
        - name: aws-cli
          image: amazon/aws-cli:latest
          command: ["/bin/bash"]
          args:
            - -c
            - |
              aws s3 sync s3://jumpstart-cache-prod-us-east-2/deepseek-llm/deepseek-llm-r1-distill-qwen-1-5b/artifacts/inference-prepack/v2.0.0 /fsx/deepseek15b
          volumeMounts:
            - name: fsx-storage
              mountPath: /fsx
          env:
            - name: AWS_DEFAULT_REGION
              value: "us-west-2"
            - name: AWS_REGION
              value: "us-west-2"
            - name: AWS_ACCESS_KEY_ID
              value: "<YOUR_ACCESS_KEY_ID>"
            - name: AWS_SECRET_ACCESS_KEY
              value: "<YOUR_SECRET_ACCESS_KEY>"
            - name: AWS_SESSION_TOKEN
              value: "<YOUR_SESSION_TOKEN>"  # 임시 자격 증명 사용 시
      volumes:
        - name: fsx-storage
          persistentVolumeClaim:
            claimName: fsx-claim
      restartPolicy: Never
  backoffLimit: 3
```

**Job 실행:**
```bash
kubectl apply -f copy_to_fsx_lustre.yaml
```

**복사 상태 확인:**
```bash
# Job 상태 확인
kubectl get jobs

# Pod 로그 확인 (복사 진행률)
kubectl logs -f job/copy-model-to-fsx
```

### Step 2: FSX File System ID 확인

```bash
kubectl get pv fsx-pv -o yaml | grep -A5 "csi:"
```

출력 예시:
```yaml
csi:
  driver: fsx.csi.aws.com
  volumeAttributes:
    dnsname: fs-09d6a597bc983fe33.fsx.us-west-2.amazonaws.com
    mountname: e3pfzb4v
  volumeHandle: fs-09d6a597bc983fe33
```

### Step 3: FSX Endpoint 배포

**deploy_fsx_lustre_inference_operator.yaml 파일에서 fileSystemId 수정:**
```yaml
apiVersion: inference.sagemaker.aws.amazon.com/v1alpha1
kind: InferenceEndpointConfig
metadata:
  name: deepseek15b-fsx
  namespace: default
spec:
  endpointName: deepseek15b-fsx
  instanceType: ml.g5.8xlarge
  invocationEndpoint: invocations
  modelName: deepseek15b
  modelSourceConfig:
    fsxStorage:
      fileSystemId: fs-09d6a597bc983fe33  # 위에서 확인한 FSX ID로 변경
    modelLocation: deepseek15b
    modelSourceType: fsx
  worker:
    environmentVariables:
    - name: HF_MODEL_ID
      value: /opt/ml/model
    - name: SAGEMAKER_PROGRAM
      value: inference.py
    - name: SAGEMAKER_SUBMIT_DIRECTORY
      value: /opt/ml/model/code
    - name: MODEL_CACHE_ROOT
      value: /opt/ml/model
    - name: SAGEMAKER_ENV
      value: '1'
    image: 763104351884.dkr.ecr.us-east-2.amazonaws.com/huggingface-pytorch-tgi-inference:2.4.0-tgi2.3.1-gpu-py311-cu124-ubuntu22.04-v2.0
    modelInvocationPort:
      containerPort: 8080
      name: http
    modelVolumeMount:
      mountPath: /opt/ml/model
      name: model-weights
    resources:
      limits:
        nvidia.com/gpu: 1
      requests:
        # ⚠️ cpu/memory 요청은 노드 인스턴스 크기에 맞춰야 합니다.
        # 아래 값(30 vCPU / 100Gi)은 ml.g5.8xlarge 기준이며, ml.g5.2xlarge
        # (8 vCPU / 32Gi)에서는 절대 스케줄되지 않아 Pod가 영원히 Pending 됩니다.
        # ml.g5.2xlarge면 cpu: 6000m / memory: 24Gi 정도로 낮추세요.
        # (자동화 스크립트 ./2.prepare_fsx_inference.sh 는 인스턴스 타입을
        #  감지해 이 값을 자동으로 맞춰줍니다.)
        cpu: 30000m
        memory: 100Gi
        nvidia.com/gpu: 1
```

**Endpoint 배포:**
```bash
kubectl apply -f deploy_fsx_lustre_inference_operator.yaml
```

**배포 상태 확인:**
```bash
# Pod 상태 확인
kubectl get pods

# 상세 이벤트 확인
kubectl describe pod -l app=deepseek15b-fsx
```

---

## 방법 2: S3 기반 Endpoint 배포

### Step 1: S3 버킷 생성 및 모델 업로드

```bash
# S3 버킷 생성 (클러스터와 같은 리전)
aws s3 mb s3://deepseek-qwen-1-5b-us-west-2 --region us-west-2

# 모델 복사
aws s3 sync s3://jumpstart-cache-prod-us-east-2/deepseek-llm/deepseek-llm-r1-distill-qwen-1-5b/artifacts/inference-prepack/v2.0.0 \
  s3://deepseek-qwen-1-5b-us-west-2/deepseek15b/ --region us-west-2
```

### Step 2: S3 Endpoint 배포

**deploy_S3_inference_operator.yaml:**
```yaml
apiVersion: inference.sagemaker.aws.amazon.com/v1alpha1
kind: InferenceEndpointConfig
metadata:
  name: deepseek15b
  namespace: default
spec:
  modelName: deepseek15b
  endpointName: deepseek15b
  instanceType: ml.g5.8xlarge
  invocationEndpoint: invocations
  modelSourceConfig:
    modelSourceType: s3
    s3Storage:
      bucketName: deepseek-qwen-1-5b-us-west-2  # 생성한 버킷 이름
      region: us-west-2                         # 버킷 리전
    modelLocation: deepseek15b
    prefetchEnabled: true
  worker:
    resources:
      limits:
        nvidia.com/gpu: 1
      requests:
        nvidia.com/gpu: 1
        cpu: 25600m
        memory: 102Gi
    image: 763104351884.dkr.ecr.us-east-2.amazonaws.com/djl-inference:0.32.0-lmi14.0.0-cu124
    modelInvocationPort:
      containerPort: 8080
      name: http
    modelVolumeMount:
      name: model-weights
      mountPath: /opt/ml/model
    environmentVariables:
      - name: OPTION_ROLLING_BATCH
        value: "vllm"
      - name: SERVING_CHUNKED_READ_TIMEOUT
        value: "480"
      - name: DJL_OFFLINE
        value: "true"
      - name: NUM_SHARD
        value: "1"
      - name: SAGEMAKER_PROGRAM
        value: "inference.py"
      - name: SAGEMAKER_SUBMIT_DIRECTORY
        value: "/opt/ml/model/code"
      - name: MODEL_CACHE_ROOT
        value: "/opt/ml/model"
      - name: SAGEMAKER_MODEL_SERVER_WORKERS
        value: "1"
      - name: SAGEMAKER_MODEL_SERVER_TIMEOUT
        value: "3600"
      - name: OPTION_TRUST_REMOTE_CODE
        value: "true"
      - name: OPTION_ENABLE_REASONING
        value: "true"
      - name: OPTION_REASONING_PARSER
        value: "deepseek_r1"
      - name: SAGEMAKER_CONTAINER_LOG_LEVEL
        value: "20"
      - name: SAGEMAKER_ENV
        value: "1"
```

**Endpoint 배포:**
```bash
kubectl apply -f deploy_S3_inference_operator.yaml
```

**배포 상태 확인:**
```bash
kubectl get pods
kubectl get svc
```

---

## Endpoint 테스트

추론 Service는 **`ClusterIP` 타입**(클러스터 내부 전용)이라 호출 방법이 두 가지입니다:

- **방법 A — 클러스터 안의 테스트 Pod에서 호출** (아래 Step 1~6). 별도 도구 없이 `kubectl`만으로 됩니다.
- **방법 B — `kubectl port-forward`로 내 노트북에서 직접 호출** (테스트 Pod 불필요):
  ```bash
  # 한 터미널: 로컬 8443 → Service 443 터널 (켜 두는 동안 유지)
  kubectl port-forward svc/deepseek15b-fsx-routing-service 8443:443

  # 다른 터미널: 내 노트북에서 바로 호출
  curl http://localhost:8443/invocations \
    -H 'Content-Type: application/json' \
    -d '{"inputs": "Hi, what can you help me with?"}'
  ```
  > S3 배포면 Service 이름을 `deepseek15b-routing-service`로 바꾸세요. (port-forward는 평문 HTTP로 터널되므로 `http://localhost:8443` 사용)

아래는 **방법 A**(테스트 Pod) 절차입니다.

### Step 1: 테스트용 Pod 생성

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-endpoint
spec:
  containers:
  - name: test
    image: python:3.11-slim
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF
```

### Step 2: Pod 상태 확인

```bash
kubectl get pod test-endpoint
```

### Step 3: Endpoint(Service) 확인

```bash
kubectl get svc | grep routing-service
kubectl get endpoints | grep routing-service
```

출력 예시:
```
NAME                              TYPE        CLUSTER-IP      PORT(S)
deepseek15b-fsx-routing-service   ClusterIP   172.20.49.99    443/TCP
deepseek15b-routing-service       ClusterIP   172.20.51.10    443/TCP
```

> **호출 주소 핵심:**
> - **Service 이름으로 호출하면 됩니다** (Pod IP를 직접 쓸 필요 없음 — IP는 Pod 재시작 시 바뀜).
>   주소: `<service-name>.<namespace>.svc.cluster.local` (같은 네임스페이스면 `<service-name>`만으로도 가능)
> - Service 포트는 `443`이지만 **프로토콜은 평문 HTTP**입니다. 따라서 `http://...:443` 으로 호출하세요.
>   `https://` 로 호출하면 `SSL: WRONG_VERSION_NUMBER` 에러가 납니다.
> - 경로는 `/invocations` 입니다.

### Step 4: FSX Endpoint 테스트

`python:3.11-slim` 이미지에는 `requests`가 없으므로, 추가 설치가 필요 없는 **표준 라이브러리 `urllib`** 를 사용합니다.

```bash
kubectl exec test-endpoint -- python3 -c '
import urllib.request, json
url = "http://deepseek15b-fsx-routing-service.default.svc.cluster.local:443/invocations"
req = urllib.request.Request(
    url,
    data=json.dumps({"inputs": "Hi, what can you help me with?"}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=120) as r:
    print("Status:", r.status)
    print("Response:", r.read().decode())
'
```

`requests`를 선호하면 먼저 설치 후 사용하세요:
```bash
kubectl exec test-endpoint -- pip install requests -q
kubectl exec test-endpoint -- python3 -c '
import requests
r = requests.post(
    "http://deepseek15b-fsx-routing-service.default.svc.cluster.local:443/invocations",
    headers={"Content-Type": "application/json"},
    json={"inputs": "Hi, what can you help me with?"},
    timeout=120,
)
print("Status:", r.status_code)
print("Response:", r.text)
'
```

### Step 5: S3 Endpoint 테스트

S3 배포의 경우 Service 이름만 다릅니다 (`deepseek15b-routing-service`):

```bash
kubectl exec test-endpoint -- python3 -c '
import urllib.request, json
url = "http://deepseek15b-routing-service.default.svc.cluster.local:443/invocations"
req = urllib.request.Request(
    url,
    data=json.dumps({"inputs": "Hi, what can you help me with?"}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=120) as r:
    print("Status:", r.status)
    print("Response:", r.read().decode())
'
```

### Step 6: 테스트 Pod 정리

```bash
kubectl delete pod test-endpoint
```

---

## 리소스 정리

### Endpoint 삭제

```bash
# FSX Endpoint 삭제
kubectl delete inferenceendpointconfig deepseek15b-fsx

# S3 Endpoint 삭제
kubectl delete inferenceendpointconfig deepseek15b
```

### 복사 Job 삭제

```bash
kubectl delete job copy-model-to-fsx
```

### S3 버킷 삭제 (선택사항)

```bash
aws s3 rb s3://deepseek-qwen-1-5b-us-west-2 --force --region us-west-2
```

---

## 유용한 명령어

```bash
# 모든 리소스 상태 확인
kubectl get pods,svc,jobs,inferenceendpointconfig

# Pod 로그 확인
kubectl logs <pod-name>

# Pod 상세 정보 (이벤트 포함)
kubectl describe pod <pod-name>

# InferenceEndpointConfig 상세 정보
kubectl describe inferenceendpointconfig <name>
```

---

## 트러블슈팅

### 1. `kubectl apply` 시 conversion webhook 에러

```
conversion webhook for inference.sagemaker.aws.amazon.com/... failed:
Post "https://hyperpod-inference-conversion-webhook.../convert...":
no endpoints available for service "hyperpod-inference-conversion-webhook"
```

**원인:** webhook을 서빙하는 `hyperpod-inference-controller-manager` Pod가 없습니다. 보통
`amazon-sagemaker-hyperpod-inference` 애드온이 `CREATE_FAILED` 상태이고, 그 뿌리는 **Kueue가
scale 0으로 죽어 있어** (`kueue-webhook-service` endpoint 없음) 애드온이 controller-manager
Deployment를 만들지 못한 것입니다. (워크샵용 Pod 정리 스크립트가 Kueue를 죽인 부작용)

```bash
# 1) 진단
kubectl get endpoints hyperpod-inference-conversion-webhook -n hyperpod-inference-system  # <none> 이면 해당
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" \
  --addon-name amazon-sagemaker-hyperpod-inference --region "$AWS_REGION" \
  --query 'addon.{Status:status,Health:health.issues}'
kubectl get deploy kueue-controller-manager -n kueue-system   # 0/0 이면 죽은 상태

# 2) Kueue 복구 (webhook endpoint 살아남)
kubectl scale deployment kueue-controller-manager -n kueue-system --replicas=1

# 3) CREATE_FAILED 애드온은 update가 안 되므로, k8s 리소스는 보존(--preserve)하고
#    등록만 지운 뒤 동일 구성으로 재생성 (재생성 시 controller-manager가 정상 생성됨)
aws eks delete-addon --cluster-name "$EKS_CLUSTER_NAME" \
  --addon-name amazon-sagemaker-hyperpod-inference --preserve --region "$AWS_REGION"
# (삭제 완료 후) 기존 configuration-values 로 다시 create-addon
```

### 2. FSx 복사 Job이 `ContainerCreating`에서 멈춤

```
MountVolume.MountDevice failed for volume "fsx-pv":
driver name fsx.csi.aws.com not found in the list of registered CSI drivers
```

**원인:** FSx CSI 드라이버의 `fsx-csi-node` DaemonSet이 없어졌습니다 (`aws-fsx-csi-driver`
애드온이 `DEGRADED`). 역시 워크샵 Pod 정리 스크립트가 슬롯 확보용으로 삭제한 부작용입니다.

```bash
kubectl get ds -n kube-system | grep fsx          # 없으면 해당
aws eks update-addon --cluster-name "$EKS_CLUSTER_NAME" \
  --addon-name aws-fsx-csi-driver --resolve-conflicts OVERWRITE --region "$AWS_REGION"
```

### 3. 추론 Pod가 계속 `Pending`

```
FailedScheduling: Insufficient cpu / Insufficient memory
```

**원인:** deploy YAML의 cpu/memory **요청값이 노드 인스턴스보다 큽니다.** 예: 기본 예시의
`cpu: 30000m / memory: 100Gi`는 `ml.g5.2xlarge`(8 vCPU / 32Gi)에 절대 안 들어갑니다.

```bash
kubectl describe pod -l app=deepseek15b-fsx | sed -n '/Events:/,$p'
# 해결: 요청값을 인스턴스에 맞게 낮춤 (g5.2xlarge → cpu 6000m / memory 24Gi)
# ./2.prepare_fsx_inference.sh 는 인스턴스 타입을 감지해 자동으로 맞춰줍니다.
```

### 4. 노드 슬롯 부족(`Too many pods` / Pending)

`ml.g5.2xlarge` 같은 인스턴스는 HyperPod이 kubelet `maxPods`를 낮게(예: 14) 고정합니다.
`../../setup/4.ensure-workshop-capacity.sh` 로 `maxPods`를 상향해 슬롯을 확보하세요
(자세한 내용은 [`../../setup/SCRIPTS.md`](../../setup/SCRIPTS.md) 참고).

### 5. Pod가 `ContainerCreating`에서 멈추고 `failed to assign an IP address`

```
Failed to create pod sandbox: ... plugin type="aws-cni" ...
add cmd: failed to assign an IP address to container
```

**원인:** **IP 고갈**입니다. 슬롯(`maxPods`)은 남아도 VPC CNI가 줄 **IP가 부족**한 상황입니다.
prefix delegation이 꺼져 있으면 `ml.g5.2xlarge`는 secondary IP를 **~14개**만 확보하므로, IP 쓰는 Pod가 그 수를 넘으면 새 Pod가 IP를 못 받습니다. (특히 `maxPods`만 28로 올리고 IP 공급을 안 늘렸을 때 발생)

```bash
# 진단: 노드의 실제 secondary IP 수 vs IP 쓰는 Pod 수
kubectl get ds aws-node -n kube-system \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep PREFIX

# 해결: VPC CNI prefix delegation 활성화 (IP를 /28 prefix=16개 블록으로 확보)
cd ../../setup && ./4.ensure-workshop-capacity.sh   # 기본으로 prefix delegation까지 켬
# 또는 직접:
aws eks update-addon --cluster-name <EKS_CLUSTER> --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE \
  --configuration-values '{"env":{"ENABLE_PREFIX_DELEGATION":"true","WARM_PREFIX_TARGET":"1"}}' \
  --region <REGION>
# 적용 후, IP를 못 받아 멈춰있던 Pod는 재생성해야 새 prefix IP를 받습니다:
kubectl delete pod -l app=deepseek15b
```

> 💡 `maxPods` 상향과 prefix delegation은 **짝**입니다. 슬롯만 늘리고 IP 공급을 안 늘리면 이 에러가 납니다. (prefix delegation은 VPC CNI에 설정되어 노드 재프로비저닝에도 유지됨)

### 6. 엔드포인트 호출 시 에러

| 증상 | 원인 / 해결 |
|---|---|
| `ModuleNotFoundError: No module named 'requests'` | `test-endpoint`(python:3.11-slim) Pod 안에 requests 없음 → `urllib` 사용하거나 `kubectl exec test-endpoint -- pip install requests` |
| `SSL: WRONG_VERSION_NUMBER` | `https://` 로 호출함 → Service 포트는 443이지만 평문 HTTP이므로 `http://...:443` 사용 |
| 연결 거부 / Pod IP 변경됨 | Pod IP 대신 **Service 이름**(`<svc>.<ns>.svc.cluster.local:443`)으로 호출 |
