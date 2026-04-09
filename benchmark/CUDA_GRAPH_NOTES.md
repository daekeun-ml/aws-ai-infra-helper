# CUDA Graph 이슈 노트

벤치마크 실험 중 발견·분석된 CUDA graph 관련 이슈 및 해결책 정리.

---

## CUDA Graph란?

GPU 명령어 시퀀스를 iteration 1에서 **녹화(capture)** 해두고, iteration 2부터 **재생(replay)** 하는 최적화 기법.

- **장점**: CPU → GPU kernel launch overhead 제거 → throughput 향상
- **단점**: 녹화 시점의 텐서 shape·메모리 포인터가 **static으로 고정**됨

```
일반 실행:  CPU → GPU 명령 전달 (매 iter)
CUDA Graph: iter 1 녹화 → iter 2~ 재생 (CPU overhead 없음)
```

---

## 두 레벨의 CUDA Graph

이 벤치마크 스택에는 독립적인 두 레벨의 CUDA graph가 존재한다.

| 레벨 | 범위 | 제어 방법 |
|--|--|--|
| **Megatron** | 전체 training step | `--cuda_graph_impl none` |
| **TransformerEngine (TE)** | 개별 transformer layer forward | `NVTE_DISABLE_CUDA_GRAPH=1` |

> **TransformerEngine(TE)**: NVIDIA가 만든 저수준 라이브러리. Attention·Linear·LayerNorm 등 Transformer 핵심 연산의 FP8·fused kernel·CUDA graph 최적화를 담당. `NVTE_` prefix 환경변수로 제어한다.

```
NeMo / Megatron
      ↓
TransformerEngine   ← TE CUDA graph (NVTE_DISABLE_CUDA_GRAPH=1)
      ↓
CUDA / cuDNN
      ↓
GPU
```

preset의 `NO_CUDA_GRAPHS=1`은 Megatron 레벨만 끈다. **TE 레벨은 별도로 꺼야 한다.**

---

## 이슈 A — FP8-CS 스케일 팩터 고정

### 영향 범위
- GPU: H100 / H200
- Precision: `fp8_cs` (current scaling)

### 원인

`fp8_cs`는 per-tensor **amax history** 기반으로 scale factor를 계산하고 별도 텐서로 관리한다.

```
실제값 = FP8값 × scale_factor
scale_factor = f(amax_history)  ← 매 iter 업데이트 필요
```

TE CUDA graph가 iter 1에서 이 scale_factor 텐서의 **포인터를 고정**한다.
iter 2부터는 scale_factor가 업데이트되어도 graph는 iter 1 값을 그대로 재생한다.

```
iter 1:  scale 캡처 = 0.5  → 녹화 완료
iter 2:  scale 업데이트 = 0.8  (무시됨)
iter 2:  graph replay → scale = 0.5 그대로 사용
→ 모든 layer output 동일 → loss 고정 → gradient = 0
```

### 증상

```
iteration  1 | lm loss: 1.258E+01 | grad norm: 9.807
iteration  2 | lm loss: 1.258E+01 | grad norm: 0.000  ← 고정
iteration  3 | lm loss: 1.258E+01 | grad norm: 0.000
...
```

### 해결책

```bash
NVTE_DISABLE_CUDA_GRAPH=1
```

26.02 스크립트(`02_run_basic.sh`, `03_run_aws_optimized.sh`)의 `NVTE_NO_CUDA_GRAPH_PATCH` 블록이 `setup_experiment.py`에 이 환경변수를 자동 주입한다.

---

## 이슈 B — mRoPE 가변 시퀀스 충돌

### 영향 범위
- 모델: Qwen3-VL (VLM 계열)
- GPU / Precision: **무관** — B200 FP8-MX, BF16에서도 발생

### 원인

**mRoPE (multimodal RoPE)**: 이미지 + 텍스트 혼합 시퀀스에서 position embedding을 계산하는 방식. 이미지 크기·개수가 샘플마다 다르기 때문에 시퀀스 길이가 매 iteration 달라진다.

CUDA graph는 iter 1의 텐서 shape을 고정하므로, 다른 shape이 들어오면 충돌한다.

```
iter 1 캡처: image tokens = 4096
iter 2 재생: image tokens = 256  ← 다른 이미지
→ RuntimeError: size of tensor a (4096) must match tensor b (256)
```

### 증상

```
RuntimeError: The size of tensor a (4096) must match the size of tensor b (256)
  File "transformer_engine/pytorch/graph.py", line 792
```

### 해결책

Megatron + TE **두 레벨 모두** 꺼야 한다.

```bash
# preset 파일에 설정
NO_CUDA_GRAPHS=1        # → --cuda_graph_impl none (Megatron 레벨)

# setup_experiment.py에 자동 주입 (NVTE_NO_CUDA_GRAPH_PATCH)
NVTE_DISABLE_CUDA_GRAPH=1   # TE 레벨
```

26.02 presets(`qwen3_vl_30b_a3b_*.conf`)에 `NO_CUDA_GRAPHS=1`이 설정되어 있다.

---

## B200 FP8-MX가 괜찮은 이유

`fp8_mx` (MXFP8, microscaling)는 scale factor 구조가 근본적으로 다르다.

| | fp8_cs | fp8_mx |
|--|--|--|
| Scale 단위 | per-tensor | 블록(32 원소)당 |
| Scale 저장 | 별도 텐서 (외부) | 데이터에 exponent 내장 |
| 업데이트 방식 | 매 iter amax 계산 | 연산 kernel 내부에서 inline 처리 |

별도의 외부 scale 텐서가 없기 때문에 CUDA graph가 고정할 대상이 존재하지 않는다.

```
loss scale: 1.0  (전 iter 고정) → 정상. fp8_mx는 동적 loss scaling 불필요.
```

---

## 모델 / GPU / Precision별 정리

| 모델 | GPU | Precision | 이슈 | 필요한 fix |
|--|--|--|--|--|
| Dense / MoE | H100 / H200 | fp8_cs | **이슈 A** | `NVTE_DISABLE_CUDA_GRAPH=1` |
| Dense / MoE | B200 / GB200 | fp8_mx | 없음 | 불필요 |
| Dense / MoE | 모든 GPU | bf16 | 없음 | 불필요 |
| Qwen3-VL | 모든 GPU | 모든 Precision | **이슈 B** | `NO_CUDA_GRAPHS=1` + `NVTE_DISABLE_CUDA_GRAPH=1` |

---

## 26.02 스크립트 반영 현황

| 항목 | 파일 | 구현 방식 |
|--|--|--|
| Megatron graph 비활성화 | `presets/qwen3_vl_*.conf` | `NO_CUDA_GRAPHS=1` → `--cuda_graph_impl none` 플래그 |
| TE graph 비활성화 | `02_run_basic.sh`, `03_run_aws_optimized.sh` | `NVTE_NO_CUDA_GRAPH_PATCH` 블록이 `setup_experiment.py`에 `NVTE_DISABLE_CUDA_GRAPH=1` 주입 |

> `setup_experiment.py`에 이미 패치가 적용된 경우 (`NVTE_NO_CUDA_GRAPH_PATCH` 마커 존재) 재실행 시 스킵된다. 초기화가 필요하면 `git checkout scripts/performance/setup_experiment.py` 후 재실행.
