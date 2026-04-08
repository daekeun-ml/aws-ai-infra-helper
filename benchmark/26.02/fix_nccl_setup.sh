#!/bin/bash
# fix_nccl_setup.sh
# setup_experiment.py의 NCCL 설정을 현재 환경에 맞게 수정합니다.
# - NCCL_NET_PLUGIN: libnccl-net-aws-ofi.so / libnccl-net-ofi.so 존재 여부로 자동 감지
# - NCCL_SOCKET_IFNAME: lo, docker0, veth_def_agent 제외
# 이미 패치된 파일에도 안전하게 재적용할 수 있습니다.
#
# 사용법:
#   ./fix_nccl_setup.sh [setup_experiment.py 경로]
#   (기본값: /fsx/megatron-bridge-test-26.02/Megatron-Bridge/scripts/performance/setup_experiment.py)

set -euo pipefail

SETUP_SCRIPT="${1:-/fsx/megatron-bridge-test-26.02/Megatron-Bridge/scripts/performance/setup_experiment.py}"

if [[ ! -f "$SETUP_SCRIPT" ]]; then
    echo "ERROR: $SETUP_SCRIPT 를 찾을 수 없습니다." >&2
    exit 1
fi

python3 - "$SETUP_SCRIPT" << 'PYEOF'
import sys, os, re

filepath = sys.argv[1]
with open(filepath) as f:
    content = f.read()

original = content

# ── 1. NCCL_NET_PLUGIN: 고정값이나 기존 자동감지 블록 모두 아래 블록으로 교체 ──
NEW_PLUGIN_BLOCK = (
    '    _ofi_lib = "/opt/amazon/ofi-nccl/lib"\n'
    '    if __import__("os").path.exists(f"{_ofi_lib}/libnccl-net-aws-ofi.so"):\n'
    '        _nccl_plugin = "aws-ofi"\n'
    '    elif __import__("os").path.exists(f"{_ofi_lib}/libnccl-net-ofi.so"):\n'
    '        _nccl_plugin = "ofi"\n'
    '    else:\n'
    '        _nccl_plugin = "ofi"\n'
    '    custom_env_vars.setdefault("NCCL_NET_PLUGIN", _nccl_plugin)'
)

# 이미 자동감지 블록이 있으면 통째로 교체, 없으면 고정값 한 줄 교체
auto_block_pat = re.compile(
    r'    _ofi_lib = .+?\n'
    r'(?:    (?:if|elif|else).+?\n)*'
    r'    custom_env_vars\.setdefault\("NCCL_NET_PLUGIN".*?\)',
    re.DOTALL
)
if auto_block_pat.search(content):
    content = auto_block_pat.sub(NEW_PLUGIN_BLOCK, content)
else:
    # 고정값 한 줄 패턴
    fixed_pat = re.compile(r'    custom_env_vars\.setdefault\("NCCL_NET_PLUGIN", "[^"]+"\)')
    content = fixed_pat.sub(NEW_PLUGIN_BLOCK, content)

# ── 2. NCCL_SOCKET_IFNAME: 어떤 값이든 올바른 값으로 교체 ──
correct_ifname = '"^lo,docker0,veth_def_agent"'
ifname_pat = re.compile(r'    custom_env_vars\.setdefault\("NCCL_SOCKET_IFNAME", "[^"]+"\)')
new_ifname_line = f'    custom_env_vars.setdefault("NCCL_SOCKET_IFNAME", {correct_ifname})'
content = ifname_pat.sub(new_ifname_line, content)

if content == original:
    print("변경 없음 (이미 올바른 상태이거나 패턴을 찾지 못함)")
    sys.exit(0)

with open(filepath, "w") as f:
    f.write(content)

# 결과 확인
for line in content.splitlines():
    if "NCCL_NET_PLUGIN" in line or "NCCL_SOCKET_IFNAME" in line or "_nccl_plugin" in line or "_ofi_lib" in line:
        print(f"  {line.strip()}")
print("완료.")
PYEOF
