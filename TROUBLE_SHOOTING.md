# 문제 해결

## 1. 연결 문제

```bash
# SSM 세션이 시작되지 않는 경우
aws ssm describe-instance-information

# SSH 연결이 안 되는 경우
# 보안 그룹에서 SSH 포트(22) 허용 확인
```

## 2. Slurm 문제

```bash
# Slurm 데몬 상태 확인
sudo systemctl status slurmd

# Slurm 컨트롤러 확인
sudo systemctl status slurmctld

# 로그 확인
sudo journalctl -u slurmd -f
```

## 3. 네트워크 문제

```bash
# EFA 드라이버 확인
fi_info -p efa

# 네트워크 인터페이스 확인
ifconfig

# NCCL 테스트
./scripts/generate-nccl-test.sh
sbatch nccl-test.sbatch
```

## 4. NCCL / aws-ofi-nccl 문제

### 4.1 설치 상태 확인

```bash
# aws-ofi-nccl 설치 확인
# 설치 경로는 환경에 따라 다를 수 있음:
#   - /opt/amazon/ofi-nccl      (HyperPod 기본)
#   - /opt/amazon/aws-ofi-nccl  (일부 AMI 또는 수동 설치)
OFI_NCCL_PATH=""
if [ -f /opt/amazon/ofi-nccl/lib/libnccl-net.so ]; then
    OFI_NCCL_PATH=/opt/amazon/ofi-nccl
elif [ -f /opt/amazon/aws-ofi-nccl/lib/libnccl-net.so ]; then
    OFI_NCCL_PATH=/opt/amazon/aws-ofi-nccl
fi

if [ -n "$OFI_NCCL_PATH" ]; then
    echo "aws-ofi-nccl: INSTALLED ($OFI_NCCL_PATH)"
    ls $OFI_NCCL_PATH/lib/
else
    echo "aws-ofi-nccl: NOT FOUND"
fi

# EFA 라이브러리 경로 확인
ls /opt/amazon/efa/lib/

# NCCL 플러그인이 로드되는지 확인 (학습 시 로그에서 확인)
# 정상: [0] NCCL INFO NET/OFI Using aws-ofi-nccl
# 비정상: [0] NCCL INFO NET/Socket ...  (EFA를 쓰지 않고 TCP fallback)
```

### 4.2 aws-ofi-nccl이 인식되지 않는 경우

`LD_LIBRARY_PATH`에 `aws-ofi-nccl` 경로가 없으면 NCCL이 EFA 대신 TCP socket으로 fallback합니다. 멀티노드 학습 속도가 비정상적으로 느리다면 이 경우를 먼저 의심하세요.

```bash
# aws-ofi-nccl 경로는 환경에 따라 다를 수 있으므로 먼저 확인 후 설정
# /opt/amazon/ofi-nccl 또는 /opt/amazon/aws-ofi-nccl 중 존재하는 경로 사용
OFI_NCCL_PATH=""
[ -d /opt/amazon/ofi-nccl ]      && OFI_NCCL_PATH=/opt/amazon/ofi-nccl
[ -d /opt/amazon/aws-ofi-nccl ]  && OFI_NCCL_PATH=/opt/amazon/aws-ofi-nccl

export LD_LIBRARY_PATH=$OFI_NCCL_PATH/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH

# NCCL 플러그인 경로 명시적 지정
export NCCL_NET_PLUGIN=$OFI_NCCL_PATH/lib/libnccl-net.so
```

### 4.3 NCCL 디버그 로그로 원인 파악

```bash
# 학습 실행 전 디버그 레벨 설정
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=NET,INIT

# 로그에서 확인할 키워드
# 정상: "NET/OFI" 또는 "Using aws-ofi-nccl"
# 비정상: "NET/Socket" (TCP fallback)
# 오류: "OFI call failed" → EFA 드라이버 또는 ofi-nccl 버전 불일치 의심
```

### 4.4 aws-ofi-nccl 재설치

```bash
./scripts/install-nccl-efa.sh
```

## 5. Pyxis 문제

### 5.1 Pyxis가 설치되어 있는데도 컨테이너 실행이 안 되는 경우

#### 원인

Slurm은 `slurmctld`(컨트롤러)가 `plugstack.conf`를 관리하고, `slurmd`(컴퓨트 노드)가 시작할 때 컨트롤러로부터 해당 설정을 가져오는 구조입니다. 아래 순서로 설치했을 때 문제가 발생합니다:

| 단계 | 행위 | 결과 |
|------|------|------|
| 1 | 컨트롤러에서 `slurmctld` 시작 | Pyxis 없는 `plugstack.conf` 생성 |
| 2 | 컴퓨트 노드에서 `slurmd` 시작 | 컨트롤러의 `plugstack.conf`(Pyxis 없음)를 가져와 캐시 |
| 3 | 컨트롤러에 Pyxis 설치 | 컨트롤러의 `plugstack.conf`에 Pyxis 추가됨 |
| 4 | 컴퓨트 노드에 Pyxis 설치 | 바이너리만 설치됨 |
| 5 | — | **컴퓨트 노드의 `slurmd`는 여전히 캐시된 구 `plugstack.conf` 사용 중** |

즉, 컨트롤러의 설정이 업데이트되었더라도 컴퓨트 노드의 `slurmd`가 재시작되지 않으면 새 설정을 반영하지 못합니다.

#### 해결 방법

```bash
# 1. 컨트롤러에서 모든 노드에 최신 설정 배포
export NUM_NODES=<노드 수>
srun -N $NUM_NODES sudo scontrol reconfigure

# 2. 컴퓨트 노드의 slurmd 재시작 (컨트롤러가 아닌 각 컴퓨트 노드에서 실행)
sudo systemctl restart slurmd

# 3. 정상 동작 검증
srun --container-image=nvcr.io#nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```

> **참고:** `scontrol reconfigure`는 `slurmctld`가 관리하는 최신 설정을 모든 `slurmd`에 다시 배포하도록 강제합니다. 이후 `slurmd`를 재시작해야 새 `plugstack.conf`(Pyxis 포함)가 실제로 로드됩니다.

## 6. GPU / CUDA 문제

### 6.1 CUDA 버전 확인

```bash
# 설치된 CUDA 버전 전체 확인
ls /usr/local/ | grep cuda

# 현재 활성 CUDA 버전 확인
nvcc --version
echo $CUDA_HOME

# GPU 상태 확인
nvidia-smi
```

### 6.2 HyperPod의 다중 CUDA 버전 관리

HyperPod 인스턴스에는 CUDA가 여러 버전(`/usr/local/cuda-12.9`, `/usr/local/cuda-13.0` 등) 동시에 설치되어 있는 경우가 많습니다. `nvcc`가 가리키는 버전과 실제 사용할 버전이 다를 수 있으므로 명시적으로 지정해야 합니다.

**sbatch 스크립트 또는 실행 전 환경 설정:**

```bash
# 사용할 CUDA 버전 지정 (기본값 설정 후 덮어쓰기 가능)
CUDA_VERSION=${CUDA_VERSION:-"12.9"}
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi
```

이렇게 하면 호출 시점에 환경 변수로 버전을 간단히 전환할 수 있습니다:

```bash
# 기본값 사용
sbatch train.sbatch

# 버전 지정
CUDA_VERSION=13.0 sbatch train.sbatch
```

### 6.3 CUDA 버전 불일치로 인한 오류

`libcuda.so` 또는 `libcudart.so` 관련 오류가 발생하면 `/usr/local/cuda` 심볼릭 링크가 의도한 버전을 가리키는지 확인하세요:

```bash
# 설치된 CUDA 버전 목록 확인
ls /usr/local/ | grep cuda
# 예시 출력: cuda  cuda-12.6  cuda-12.8  cuda-12.9  cuda-13.0

# 현재 심볼릭 링크가 가리키는 버전 확인
ls -la /usr/local/cuda
```

원하는 버전으로 심볼릭 링크를 변경합니다:

```bash
# 사용 가능한 버전 중 하나를 선택하여 변경
sudo ln -sfn /usr/local/cuda-<VERSION> /usr/local/cuda

# 예: cuda-13.0으로 변경
sudo ln -sfn /usr/local/cuda-13.0 /usr/local/cuda

# 변경 확인
ls -la /usr/local/cuda
nvcc --version
```

### 6.4 cuDNN / NCCL 버전 확인

```bash
# cuDNN 버전
cat /usr/local/cuda/include/cudnn_version.h | grep CUDNN_MAJOR -A 2

# NCCL 버전
cat /usr/local/cuda/include/nccl.h | grep NCCL_VERSION_CODE || \
  python3 -c "import torch; print('NCCL:', torch.cuda.nccl.version())"
```

### 6.5 GPU 장애 의심

```bash
# ECC 오류 및 상세 GPU 상태 확인
nvidia-smi -q | grep -A 5 "ECC Errors"

# 온도 / 전력 실시간 모니터링
nvidia-smi dmon -s pucvmet

# 노드 드레인 후 교체
scontrol update nodename=<node-name> state=drain reason="GPU failure"
aws sagemaker batch-replace-cluster-nodes \
  --cluster-name <cluster-name> \
  --node-ids <instance-id>
```

## 7. 노드 관리 문제

### 7.1 노드가 Slurm "down" 상태인 경우

```bash
# 노드 상태 및 원인 확인
sinfo -N -l
sinfo -o "%N %T %30E"
scontrol show node <node-name>

# HyperPod API로 노드 상태 확인
aws sagemaker list-cluster-nodes --cluster-name <cluster-name>

# slurmd 재시작 후 노드 재개
sudo systemctl restart slurmd
scontrol update nodename=<node-name> state=resume

# 노드 재부팅
aws sagemaker batch-reboot-cluster-nodes \
  --cluster-name <cluster-name> \
  --node-ids <instance-id>

# 노드 교체 (하드웨어 문제 의심 시)
aws sagemaker batch-replace-cluster-nodes \
  --cluster-name <cluster-name> \
  --node-ids <instance-id>
```

### 7.2 작업이 PENDING / COMPLETING 상태에서 멈춘 경우

컨트롤러 캐시 문제나 상태 불일치가 원인인 경우가 많습니다.

```bash
# slurmctld 재시작으로 상태 복구
sudo systemctl restart slurmctld
sudo journalctl -u slurmctld -n 100

# 설정 재배포
scontrol reconfigure

# 강제 재시작이 필요한 경우
sudo systemctl stop slurmctld
sudo pkill -9 slurmctld
sudo systemctl start slurmctld
```

### 7.3 노드 예기치 않게 재부팅된 경우

```bash
# 노드 상태 확인 및 slurmd 재시작
scontrol show node <node-name>
sudo systemctl start slurmd
sudo systemctl enable slurmd   # 재부팅 후 자동 시작 설정
scontrol update nodename=<node-name> state=resume

# 계획된 재부팅 절차 (drain → reboot → resume)
scontrol update nodename=<node-name> state=drain reason="Planned reboot"
aws sagemaker batch-reboot-cluster-nodes \
  --cluster-name <cluster-name> \
  --node-ids <instance-id>
scontrol update nodename=<node-name> state=resume
```

### 7.4 Slurm 노드명에서 EC2 인스턴스 ID 찾기

Slurm 노드명(`ip-10-1-123-45`)에서 실제 EC2 인스턴스 ID(`i-abcd12345678`)가 필요한 경우:

```bash
# 방법 1: resource_config.json 조회 (헤드 노드에서)
NODE_NAME="ip-10-1-123-45"
IP_ADDRESS=$(echo $NODE_NAME | sed 's/ip-//; s/-/./g')
sudo cat /opt/ml/config/resource_config.json | jq | grep -A 3 "$IP_ADDRESS"

# 방법 2: HyperPod API로 전체 노드 목록 조회
aws sagemaker list-cluster-nodes --cluster-name <cluster-name>
```

## 8. 성능 문제

### 8.1 NCCL 타임아웃 / 분산 학습 실패

**주요 에러 메시지:**
- `NCCL timeout in call to...`
- `NCCL communicator was aborted`
- `Net/IB : Got completion with error`

**진단 단계:**

```bash
# 1. NCCL 디버그 로그 활성화
export NCCL_DEBUG=INFO

# 2. EFA 어댑터 정상 동작 확인
fi_info -p efa

# 3. 노드 쌍별 NCCL 대역폭 테스트 (문제 있는 연결 식별)
./scripts/generate-nccl-test.sh
sbatch nccl-test.sbatch

# 4. 보안 그룹에서 노드 간 트래픽 차단 여부 확인
#    → 자체 참조 인바운드/아웃바운드 All traffic 규칙 필요
```

**해결 단계:**

```bash
# 타임아웃 값 증가
export NCCL_TIMEOUT=3600

# EFA RDMA 활성화
export FI_EFA_USE_DEVICE_RDMA=1

# 낮은 대역폭 또는 오류가 발생하는 노드 드레인 및 교체
scontrol update nodename=<node-name> state=drain reason="NCCL low bandwidth"
aws sagemaker batch-replace-cluster-nodes \
  --cluster-name <cluster-name> \
  --node-ids <instance-id>

# 메모리 압박이 원인인 경우: 배치 크기 축소 또는 병렬화 전략 조정
```

### 8.2 멀티노드 학습 속도가 비정상적으로 느린 경우

NCCL 로그에서 `NET/Socket`이 보이면 EFA 대신 TCP fallback 중입니다. [4. NCCL / aws-ofi-nccl 문제](#4-nccl--aws-ofi-nccl-문제) 섹션을 참고하세요.

```bash
# 노드 간 네트워크 토폴로지 확인
nvidia-smi topo -m

# EFA 어댑터 확인
fi_info -p efa
```

## 9. 메모리 문제

### 9.1 `Cannot allocate memory` at `os.fork()` (DataLoader 오류)

EFA Huge Pages 설정이 원인인 경우가 많습니다.

```bash
# 가장 빠른 해결책
export FI_EFA_USE_HUGE_PAGE=0

# 영구 적용 (재부팅 후에도 유지)
echo "FI_EFA_USE_HUGE_PAGE=0" | sudo tee -a /etc/environment

# 공유 메모리 사용량 확인
df -h /dev/shm
free -h
```

DataLoader 워커 수(`num_workers`)를 줄이거나 `persistent_workers=True`로 설정하는 것도 효과적입니다.

## 10. 스토리지 문제

### 10.1 루트 볼륨 공간 부족

HyperPod 루트 볼륨은 100GB 고정으로 변경이 불가합니다. 대신 아래 경로를 활용하세요:

| 경로 | 설명 | 용도 |
|------|------|------|
| `/opt/sagemaker` | 보조 EBS 볼륨 | 체크포인트, 캐시 |
| `/opt/dlami/nvme` | NVMe 인스턴스 스토리지 (p4d/p5 등) | 임시 파일, 고속 I/O |
| FSx for Lustre | 공유 파일시스템 | 데이터셋, 모델 |

```bash
# 디스크 사용량 확인
df -h
sudo du -h --max-depth=1 / | sort -hr | head -20

# 루트 볼륨 정리
sudo rm -f /var/log/*.log.* /var/log/*/*.gz
sudo rm -rf /tmp/*
sudo apt-get clean

# 캐시 디렉토리를 보조 스토리지로 리디렉션
export TORCH_HOME=/opt/sagemaker/torch_cache
export HF_HOME=/opt/sagemaker/huggingface_cache
export TRANSFORMERS_CACHE=/opt/sagemaker/transformers_cache
export TMPDIR=/opt/dlami/nvme/tmp
```

## 11. 배포 문제

### 11.1 라이프사이클 스크립트 실행 오류

```bash
# CloudWatch 로그에서 오류 확인
# Log Group:  /aws/sagemaker/Clusters/<cluster-name>/<cluster-id>
# Log Stream: LifecycleConfig/<node-group-name>/<instance-id>

# 스크립트 라인 엔딩 확인 (Windows CRLF → LF)
file script.sh   # "ASCII text" 이어야 정상
dos2unix script.sh

# S3 접근 권한 확인 (IAM 역할에 s3:GetObject, s3:ListBucket 필요)
aws s3 ls s3://<your-bucket>/
```

### 11.2 용량 부족으로 클러스터 생성 실패

`InsufficientInstanceCapacity` 오류가 발생하는 경우:

- **Flexible Training Plans** 사용 (용량 예약)
- 다른 AZ로 변경 후 재시도
- AWS 계정팀에 Reserved Capacity 요청

```bash
# 클러스터 이벤트로 원인 확인
aws sagemaker list-cluster-events --cluster-name <cluster-name>
```

### 11.3 SSM 세션 연결 실패

```bash
# SSM 플러그인 설치 확인
session-manager-plugin --version

# HyperPod 전용 타겟 형식 사용 (일반 EC2 형식과 다름)
aws ssm start-session \
  --target sagemaker-cluster:<cluster-name>_<node-group>-<instance-id>

# SSH over SSM (~/.ssh/config)
Host my-hyperpod-node
  HostName sagemaker-cluster:<cluster-id>_<node-group>-<instance-id>
  User ubuntu
  IdentityFile ~/keys/my-key.pem
  ProxyCommand aws ssm start-session --target %h \
    --document-name AWS-StartSSHSession --parameters portNumber=%p
```

## 12. 파일시스템 성능 문제

### 12.1 느린 I/O / 데이터 로딩 병목

```bash
# CloudWatch 메트릭 확인 (IOPS, 처리량, 읽기/쓰기 바이트)
# 메트릭이 프로비저닝 한계에 도달했는지 확인

# 파일시스템 용량 확인
df -h

# 높은 I/O 발생 프로세스 확인
iostat -x 1
iotop
```

**개선 방법:**

| 파일시스템 | 조치 |
|-----------|------|
| FSx for Lustre | 스토리지 용량 증가 (처리량 자동 스케일) |
| FSx for OpenZFS | IOPS / 처리량 직접 증가 |
| EBS | gp3/io2로 볼륨 타입 업그레이드 또는 IOPS 증가 |

## 13. 진단 데이터 수집

이슈 보고 시 아래 정보를 함께 첨부하면 빠른 해결에 도움이 됩니다:

```bash
# 클러스터 설정 및 노드 상태
aws sagemaker describe-cluster --cluster-name <cluster-name>
aws sagemaker list-cluster-nodes --cluster-name <cluster-name>
aws sagemaker list-cluster-events --cluster-name <cluster-name>

# Slurm 상태
sinfo -N -l
squeue -a
scontrol show node <node-name>

# 시스템 로그
sudo journalctl -u slurmd -n 200
sudo journalctl -u slurmctld -n 200

# CloudWatch 로그
# Log Group: /aws/sagemaker/Clusters/<cluster-name>/<cluster-id>
```

> **자동 수집 도구:** [hyperpod_issue_report](https://github.com/shimomut/sagemaker-solutions/tree/main/hyperpod_issue_report) — 클러스터 설정, 노드 상태, 이벤트, CloudWatch 로그를 한 번에 수집합니다.

## 추가 리소스

### AWS 공식 문서
- [SageMaker HyperPod Troubleshooting Guide](https://awslabs.github.io/ai-on-sagemaker-hyperpod/docs/common/troubleshooting-guide)
- [SageMaker HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- [HyperPod 트러블슈팅 가이드](https://awslabs.github.io/ai-on-sagemaker-hyperpod/docs/common/troubleshooting-guide)
- [EKS 트러블슈팅 가이드](https://docs.aws.amazon.com/eks/latest/userguide/troubleshooting.html)
- [FSx for Lustre 문서](https://docs.aws.amazon.com/fsx/latest/LustreGuide/)
- [EFA 사용자 가이드](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)

### 분산 학습 / 네트워크
- [NCCL 문서](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [aws-ofi-nccl GitHub](https://github.com/aws/aws-ofi-nccl)
- [Slurm 공식 문서](https://slurm.schedmd.com/)
- [Pyxis GitHub](https://github.com/NVIDIA/pyxis)
- [Enroot GitHub](https://github.com/NVIDIA/enroot)
