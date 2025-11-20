#!/bin/bash

# SageMaker HyperPod pyxis 설정 확인 스크립트

echo "=== SageMaker HyperPod Pyxis 설정 확인 ==="

# 1. Docker 설치 확인
echo "1. Docker 설치 확인..."
if command -v docker &> /dev/null; then
    echo "✓ Docker 설치됨: $(docker --version)"
else
    echo "✗ Docker가 설치되지 않았습니다"
    exit 1
fi

# 2. Enroot 설치 확인
echo -e "\n2. Enroot 설치 확인..."
if command -v enroot &> /dev/null; then
    echo "✓ Enroot 설치됨: $(enroot --version)"
else
    echo "✗ Enroot가 설치되지 않았습니다"
    exit 1
fi

# 3. Slurm 설치 확인
echo -e "\n3. Slurm 설치 확인..."
if command -v srun &> /dev/null; then
    echo "✓ Slurm 설치됨"
    if srun --help 2>&1 | grep -q "container-image"; then
        echo "✓ Slurm에서 Pyxis 컨테이너 옵션 지원"
    else
        echo "✗ Slurm에서 Pyxis 컨테이너 옵션을 찾을 수 없습니다"
    fi
else
    echo "✗ Slurm이 설치되지 않았습니다"
    exit 1
fi

# 4. Enroot 설정 확인
echo -e "\n4. Enroot 설정 확인..."
if [ -f /etc/enroot/enroot.conf ]; then
    echo "✓ Enroot 설정 파일 존재"
    if grep -q "ENROOT_RUNTIME_PATH.*nvme" /etc/enroot/enroot.conf 2>/dev/null; then
        echo "✓ NVMe 스토리지 경로 설정됨"
        grep "ENROOT_RUNTIME_PATH" /etc/enroot/enroot.conf
    else
        echo "⚠ NVMe 스토리지 경로가 설정되지 않았을 수 있습니다"
    fi
else
    echo "✗ Enroot 설정 파일이 없습니다"
fi

# 5. Docker 데이터 루트 확인
echo -e "\n5. Docker 데이터 루트 확인..."
if [ -f /etc/docker/daemon.json ]; then
    echo "✓ Docker daemon.json 존재"
    if grep -q "nvme" /etc/docker/daemon.json 2>/dev/null; then
        echo "✓ NVMe 스토리지로 설정됨"
        cat /etc/docker/daemon.json
    else
        echo "⚠ NVMe 스토리지로 설정되지 않았을 수 있습니다"
    fi
else
    echo "✗ Docker daemon.json이 없습니다"
fi

# 6. Pyxis 기능 테스트 (실제 컨테이너 실행)
echo -e "\n6. Pyxis 기능 테스트..."
echo "CUDA 컨테이너로 nvidia-smi 실행 테스트..."
# if timeout 30 srun --container-image=alpine:latest echo "Pyxis 작동 확인" &> /tmp/pyxis_test.log; then
#     echo "✓ Pyxis로 컨테이너 실행 성공"
#     cat /tmp/pyxis_test.log
if timeout 60 srun --container-image=nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi &> /tmp/pyxis_test.log; then
    echo "✓ Pyxis로 GPU 컨테이너 실행 성공"
    echo "출력 미리보기:"
    cat /tmp/pyxis_test.log
else
    echo "✗ Pyxis 테스트 실패"
    echo "에러 로그:"
    cat /tmp/pyxis_test.log
fi

echo -e "\n=== 확인 완료 ==="
