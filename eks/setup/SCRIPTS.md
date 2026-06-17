# 스크립트 설명서 (eks/setup)

이 폴더의 스크립트들은 **HyperPod EKS 클러스터를 만든 직후, 실제로 학습/추론 잡을 돌릴 수 있는 상태까지 세팅**하기 위한 것입니다.
각 스크립트가 **왜 필요한지(Why)** 를 먼저 쉽게 설명하고, **무엇을 하는지(What)** 를 정리했습니다.

---

## 한눈에 보기

| 순서 | 스크립트 | 한 줄 요약 |
|:---:|---|---|
| 1 | `1.create-config.sh` | 일반 AWS 계정용. 클러스터·네트워크 정보를 모아 `env_vars`에 저장 |
| 1 | `1.create-config-workshop.sh` | 워크샵(Workshop Studio)용. 위와 같지만 CloudFormation 없이 동작 |
| 2 | `2.setup-eks-access.sh` | 클러스터 접근 권한 + `kubectl`/`helm` 준비 |
| 3 | `3.validate-cluster.sh` | 클러스터가 제대로 준비됐는지 종합 점검 |
| 4 | `4.free_idle_pods_for_workshop.sh` | (선택) 저사양 워크샵에서 Pod 슬롯 확보 |
| 헬퍼 | `ensure-awscli.sh` | 최신 AWS CLI 자동 설치 (1번 스크립트가 자동 호출) |
| 유틸 | `check-node-availability.sh` | 노드별 남은 Pod 슬롯 빠르게 확인 |
| 부트스트랩 | `lifecycle-scripts/on_create.sh` | 노드 생성 시 자동 실행되는 디스크/containerd 세팅 |

**기본 실행 흐름:** `1` → `2` → `3` → (필요 시 `4`) → `source env_vars`

---

## 1. `1.create-config.sh` / `1.create-config-workshop.sh`

> **Why — 왜 하나?**
> 뒤따르는 모든 스크립트(`2`, `3`, `4`)는 "EKS 클러스터 이름이 뭔지", "어떤 VPC·서브넷·보안그룹을 쓰는지", "S3 버킷·실행 역할은 무엇인지"를 알아야 동작합니다.
> 이 정보를 **매번 손으로 찾지 않도록**, 한 번에 자동으로 수집해서 `env_vars` 파일에 저장해 둡니다. 이후 스크립트들은 이 파일만 읽으면 됩니다.

**What — 하는 일 (공통)**
- (먼저) `ensure-awscli.sh`를 불러 **최신 AWS CLI v2를 보장** — 오래된 CLI는 HyperPod 정보를 못 읽기 때문 (아래 헬퍼 설명 참고)
- `AWS_REGION` 결정 (환경변수 없으면 `aws configure`의 기본 리전 사용)
- HyperPod 클러스터 선택 (여러 개면 목록에서 고름, 하나면 자동 선택)
- EKS 클러스터 이름·ARN, VPC ID, 프라이빗 서브넷, 보안그룹, S3 버킷, 실행 역할(Execution Role)을 찾아냄
- 결과를 모두 `env_vars`에 `export ...` 형태로 저장

**두 버전의 차이 — 어느 걸 써야 하나?**

| | `1.create-config.sh` | `1.create-config-workshop.sh` |
|---|---|---|
| 대상 | **일반 AWS 계정** | **핸즈온 워크샵 (Workshop Studio)** |
| 정보 출처 | **CloudFormation 스택 Outputs**에서 추출 | CloudFormation에 **의존하지 않음** |
| EKS 찾는 법 | `aws eks list-clusters`에서 이름 매칭 | `aws sagemaker describe-cluster`의 `Orchestrator.Eks` 사용 |
| S3 버킷 | 스택 Output에서 자동 | 후보 목록에서 **직접 선택** |

> 💡 직접 만든 클러스터(CloudFormation 스택 존재)면 **`1.create-config.sh`**, 워크샵 제공 환경이면 **`1.create-config-workshop.sh`** 를 쓰세요.

```bash
./1.create-config.sh            # 일반 계정
# 또는
./1.create-config-workshop.sh   # 워크샵
```

---

## 2. `2.setup-eks-access.sh`

> **Why — 왜 하나?**
> 클러스터를 `kubectl`이나 `helm`으로 조작하려면 두 가지가 필요합니다:
> ① **AWS 쪽에서 "이 사용자가 클러스터에 접근해도 된다"는 권한**(EKS Access Entry + 관리자 정책),
> ② **내 PC가 클러스터에 어떻게 접속하는지 적힌 설정 파일**(kubeconfig).
> 이게 없으면 `kubectl get nodes`조차 거부됩니다. 이 스크립트가 둘 다 자동으로 설정하고, `kubectl`·`helm`이 없으면 설치까지 해줍니다.

**What — 하는 일**
- 현재 사용자 ARN 확인 (assumed-role면 EKS가 인식하는 role ARN으로 변환)
- **EKS Access Entry 생성** (이미 있으면 건너뜀)
- **`AmazonEKSClusterAdminPolicy` 연결** — 클러스터 관리자 권한 부여 (이미 있으면 건너뜀)
- **kubeconfig 업데이트** (`aws eks update-kubeconfig`)
- `kubectl` 없으면 설치 (**OS/아키텍처 자동 감지** — Linux/macOS, x86_64/ARM)
- `kubectl get nodes`로 접근 확인
- `helm` 없으면 설치 (공식 `get-helm-3` 스크립트)
- 권한 전파를 15초 기다린 뒤 `helm list`로 helm 접근 확인
- HyperPod `health-monitoring-agent` 데몬셋 상태 확인

```bash
./2.setup-eks-access.sh
```

---

## 3. `3.validate-cluster.sh`

> **Why — 왜 하나?**
> 학습/추론 잡을 올리기 전에 **클러스터가 정말 잡을 받을 준비가 됐는지** 미리 확인하기 위해서입니다.
> GPU·EFA가 인식되는지, 학습 오퍼레이터가 떠 있는지, 잡을 만들 권한이 있는지, 스토리지가 붙어 있는지를 한 번에 점검해서 "막상 돌렸더니 안 됨"을 방지합니다.

**What — 점검 항목 (각각 ✅/❌로 표시)**
- `helm` 설치 확인 (없으면 설치)
- 클러스터 연결 상태
- 노드 목록 + **GPU·EFA 가용성**
- **Kubeflow Training Operator** 동작 여부
- **NVIDIA GPU device plugin** 존재 여부
- **AWS EFA device plugin** 존재 여부
- 잡 생성 권한 (`pytorchjobs`, `pods`, `services`)
- **StorageClass** 존재 여부
- **Persistent Volume(PV)** 존재 여부
- 네임스페이스 목록

```bash
./3.validate-cluster.sh
```

---

## 4. `4.free_idle_pods_for_workshop.sh`  *(선택)*

> **Why — 왜 하나?**
> `ml.g5.2xlarge` 같은 **저사양 인스턴스는 노드 하나가 받을 수 있는 Pod 개수가 적습니다.**
> 그런데 Kueue·KEDA·각종 컨트롤러 같은 시스템 Pod가 슬롯을 다 차지하면, 정작 핸즈온에서 띄우려는 학습/추론 Pod가 슬롯 부족으로 배포에 실패합니다.
> 그래서 워크샵에 당장 필요 없는 시스템 Pod들을 정리해 **슬롯을 비워 줍니다.**

> ⚠️ **저사양 인스턴스로 워크샵을 돌릴 때만** 실행하세요. 일반 운영 클러스터에서는 필요한 컴포넌트까지 줄일 수 있으니 쓰지 마세요.

**What — 하는 일**
- Kueue webhook 삭제 / Kueue 컨트롤러 scale-down
- KEDA 관련 컴포넌트 삭제
- inference operator·observability 컨트롤러 scale-down/삭제
- 완료(`Succeeded`)된 Pod 정리
- 중복 컨트롤러 정리, CoreDNS 레플리카 축소, FSx CSI node 데몬셋 삭제
- (있으면) PVC 바인딩 어노테이션 수정
- 마지막에 **노드별 Pod 사용량(현재/최대)** 출력

```bash
./4.free_idle_pods_for_workshop.sh
```

---

## 헬퍼: `ensure-awscli.sh`

> **Why — 왜 하나?**
> HyperPod 클러스터의 EKS 정보는 `aws sagemaker describe-cluster` 응답의 `Orchestrator.Eks.ClusterArn` 필드에 들어 있습니다.
> 그런데 **오래된 AWS CLI(예: 2.17.x)는 이 필드 자체를 모릅니다.** 그러면 값이 비어서 `1.create-config*.sh`가 "EKS 클러스터를 못 찾음"이라는 오해를 부르는 에러로 죽습니다.
> 이 헬퍼가 **최신 AWS CLI v2를 자동 설치**해서 그 문제를 원천 차단합니다.

**What — 하는 일**
- `1.create-config*.sh` 시작 시 자동으로 호출됨 (직접 실행도 가능)
- **OS/아키텍처 자동 감지** 후 최신 AWS CLI v2 설치
  - Linux: `x86_64` / `aarch64` zip 인스톨러
  - macOS: 유니버설 `.pkg` 인스톨러
- 오프라인/에어갭 등으로 설치를 건너뛰려면 `SKIP_AWSCLI_INSTALL=1` 설정

```bash
./ensure-awscli.sh            # 단독 실행도 가능
SKIP_AWSCLI_INSTALL=1 ./1.create-config.sh   # 설치 건너뛰기
```

---

## 유틸: `check-node-availability.sh`

> **Why — 왜 하나?**
> 배포가 자꾸 실패할 때 "혹시 Pod 슬롯이 꽉 찼나?"를 **빠르게 확인**하기 위한 가벼운 유틸입니다.

**What — 하는 일**
- 각 노드의 **현재 Pod 수 / 최대 Pod 수**를 한 줄씩 출력

```bash
./check-node-availability.sh
```

---

## 부트스트랩: `lifecycle-scripts/on_create.sh`

> **Why — 왜 하나?**
> 이 스크립트는 사람이 직접 돌리는 게 아니라, **HyperPod가 노드를 새로 만들 때 노드 안에서 자동 실행**되는 lifecycle 스크립트입니다 (S3에 올려 두면 클러스터 생성 시 실행됨).
> 컨테이너 이미지·레이어는 용량을 많이 먹는데, 이를 작은 루트 디스크가 아니라 **보조 EBS 볼륨(`/opt/sagemaker`)에 저장**하도록 containerd를 설정해 디스크 부족을 막습니다.

**What — 하는 일**
- `/opt/sagemaker`(보조 EBS) 마운트를 최대 60초 대기
- **OS 버전 감지** 후 분기 처리
  - **Amazon Linux 2**: `containerd-config.toml`의 `root` 경로를 `/opt/sagemaker/...`로 수정
  - **Amazon Linux 2023**: 커스텀 containerd config + systemd override 생성 (NVIDIA 런타임, CDI 등 포함), 기존 data-root 정리 후 이전
- 모든 로그를 `/var/log/provision/provisioning.log`에 기록

> 📌 이 파일은 보통 클러스터 생성/노드 재프로비저닝 시점에만 관여하며, 위 1~4번 세팅 흐름과는 별개입니다. (관련 트러블슈팅은 `README.md` 하단 참고)

---

## 마지막 단계

세팅이 끝나면 환경 변수를 현재 셸에 로드하세요:

```bash
source ./env_vars
```

> 더 자세한 실행 순서·트러블슈팅은 [`README.md`](./README.md)를 참고하세요.
