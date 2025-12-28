#!/usr/bin/env python3
"""
SageMaker HyperPod Inference KV Cache & Intelligent Routing 벤치마크
- Total Latency, TTFT (P90, P95, P99), Throughput (TPS) 측정
- 동시 요청 20건 (병렬)
- 같은 prefix vs 다른 prefix 비교
- 4K 토큰 컨텍스트
"""

import boto3
import json
import time
import numpy as np
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

# 설정
ENDPOINT_NAME = "deepseek7b-endpoint"
REGION = "us-east-2"
MODEL_NAME = "/opt/ml/model"
CONCURRENT_REQUESTS = 20

runtime = boto3.client("sagemaker-runtime", region_name=REGION)

# 4K 토큰 컨텍스트 (약 3000자)
LONG_CONTEXT = """
# 2024 글로벌 AI 산업 종합 보고서

## 1. 시장 개요
글로벌 AI 시장은 2024년 5,000억 달러 규모로 성장했으며, 연평균 35% 성장률을 기록하고 있습니다.

### 1.1 지역별 분석
북미는 45% 점유율로 최대 시장입니다. 미국은 OpenAI, Google, Microsoft, Amazon 등 빅테크 기업의 본거지로 AI 연구개발을 주도하고 있습니다. 실리콘밸리 스타트업 생태계도 활발하며, 2024년 상반기 AI 스타트업 투자가 250억 달러를 넘었습니다.

유럽은 25% 점유율이며, GDPR 기반 강력한 규제 프레임워크로 책임 있는 AI 개발을 선도합니다. EU AI Act 시행으로 위험 기반 AI 규제가 본격화되었으며, 이는 글로벌 AI 거버넌스의 표준이 되고 있습니다.

아시아태평양은 30% 점유율로 가장 빠른 성장세입니다. 중국은 자체 LLM 개발과 AI 칩 제조에 집중하며 기술 자립을 추구하고, 한국은 삼성과 LG 중심으로 AI 반도체와 가전에 AI를 통합하고 있습니다.

### 1.2 산업별 적용
금융에서는 사기 탐지, 신용 평가, 알고리즘 트레이딩, 고객 서비스 자동화에 AI를 활용합니다. JP Morgan, Goldman Sachs 등 주요 금융기관들은 AI 연구팀을 확대하고 있습니다.

헬스케어에서는 AI 기반 진단 보조 시스템이 의료 현장에 보급되고 있습니다. 영상 진단, 병리 분석, 신약 개발, 환자 모니터링에서 AI 정확도가 인간 전문가 수준에 도달하고 있습니다.

제조업에서는 품질 관리, 예측 정비, 공급망 최적화, 로봇 자동화에 AI를 활용하며 스마트 팩토리를 구현하고 있습니다.

리테일에서는 개인화 추천, 재고 관리, 수요 예측, 고객 서비스 챗봇에 AI가 필수적인 요소가 되었습니다.

## 2. 기술 트렌드

### 2.1 생성형 AI
2024년은 생성형 AI가 실용화 단계로 진입한 해입니다. GPT-4, Claude 3, Gemini Ultra 등 LLM 성능이 크게 향상되었으며, 텍스트, 이미지, 비디오, 오디오, 코드 생성이 가능해졌습니다.

기업들은 범용 LLM을 자사 데이터로 파인튜닝하거나 RAG 기법을 활용하여 특화된 AI 솔루션을 구축하고 있습니다.

### 2.2 멀티모달 AI
텍스트, 이미지, 오디오, 비디오를 통합 처리하는 멀티모달 AI가 주목받고 있습니다. GPT-4V, Gemini는 이미지를 이해하고 설명할 수 있으며, 실시간 번역, 콘텐츠 생성, 의료 진단에서 혁신적 결과를 보여줍니다.

### 2.3 엣지 AI
클라우드 의존도를 낮추고 실시간 처리와 프라이버시를 강화하기 위해 엣지 디바이스에서 AI 모델을 실행하는 추세가 확산되고 있습니다.

## 3. 주요 기업

### 3.1 빅테크
OpenAI는 GPT-4 Turbo를 출시하고 ChatGPT Enterprise를 확대하며 기업 시장을 공략하고 있습니다. Microsoft와의 파트너십으로 Azure AI에 깊이 통합되었습니다.

Google은 Gemini 모델 패밀리를 발표하며 멀티모달 AI 경쟁에서 우위를 점하려 하고 있습니다. Workspace 전 제품에 AI를 통합하고 있습니다.

Microsoft는 Copilot을 Windows, Office, GitHub 등 모든 제품군에 확대하며 AI-first 전략을 추진하고 있습니다.

Amazon은 Bedrock 서비스로 다양한 파운데이션 모델을 제공하고, Q 어시스턴트를 출시하여 AWS 사용자 생산성을 높이고 있습니다.

Meta는 LLaMA 3를 오픈소스로 공개하며 AI 민주화에 기여하고 있습니다.

### 3.2 스타트업
AI 스타트업 투자가 폭발적으로 증가하고 있습니다. 2024년 상반기 250억 달러가 투자되었으며, 주요 분야는 AI 에이전트, 수직 특화 LLM, AI 인프라, AI 보안입니다.

## 4. 규제 및 윤리

### 4.1 규제
EU AI Act가 2024년 본격 시행되며 위험 기반 AI 규제의 글로벌 표준이 되고 있습니다. 미국은 주 정부 차원에서 AI 규제 법안이 발의되고 있습니다.

중국은 생성형 AI 서비스 규제를 강화하며 콘텐츠 검열과 데이터 보안을 중시하고 있습니다. 한국은 AI 기본법 제정을 추진하고 있습니다.

### 4.2 윤리
AI의 편향성과 공정성 문제가 지속적으로 제기되고 있습니다. 학습 데이터의 편향이 AI 결정에 영향을 미치며, 채용, 대출, 형사사법에서 차별로 이어질 수 있습니다.

## 5. 미래 전망

### 5.1 단기 (2025-2026)
AGI 연구가 가속화될 것입니다. 현재 LLM을 넘어 더 범용적이고 자율적인 AI 시스템 개발이 진행될 것입니다.

AI 에이전트의 실용화가 확대되어 복잡한 업무를 자동화하고 인간과 협업하는 사례가 증가할 것입니다.
""" * 2  # 약 4K 토큰

# 다른 prefix 컨텍스트들
DIFFERENT_CONTEXTS = [
    f"DOCUMENT_{i}: " + "완전히 다른 내용입니다. " * 400 for i in range(20)
]

def invoke_with_streaming(payload, session_id):
    """스트리밍으로 TTFT 측정"""
    payload_with_session = {**payload, "user_id": session_id, "stream": True}
    
    start_time = time.time()
    ttft = None
    
    try:
        response = runtime.invoke_endpoint_with_response_stream(
            EndpointName=ENDPOINT_NAME,
            ContentType="application/json",
            Body=json.dumps(payload_with_session)
        )
        
        event_stream = response['Body']
        for event in event_stream:
            if 'PayloadPart' in event:
                if ttft is None:
                    ttft = time.time() - start_time
                break
        
        # 스트림 완전히 소비하고 닫기
        try:
            for _ in event_stream:
                pass
        except:
            pass
        
        return ttft
    except Exception as e:
        return None

def invoke_endpoint(payload, session_id):
    """일반 호출로 전체 지연시간 측정"""
    payload_with_session = {**payload, "user_id": session_id}
    
    start_time = time.time()
    
    try:
        response = runtime.invoke_endpoint(
            EndpointName=ENDPOINT_NAME,
            ContentType="application/json",
            Body=json.dumps(payload_with_session)
        )
        
        latency = time.time() - start_time
        result = json.loads(response["Body"].read().decode())
        
        return {
            'success': True,
            'latency': latency,
            'total_tokens': result['usage']['total_tokens'],
            'completion_tokens': result['usage']['completion_tokens']
        }
    except Exception as e:
        return {'success': False, 'error': str(e)}

def single_request(request_id, context, session_id):
    """단일 요청 실행"""
    payload = {
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": f"{context}\n\n질문: 요약해주세요."}],
        "max_tokens": 100,
        "temperature": 0.7
    }
    
    # TTFT 측정
    ttft = invoke_with_streaming(payload, session_id)
    
    # 전체 지연시간 측정
    result = invoke_endpoint(payload, session_id)
    
    if result['success']:
        return {
            'request_id': request_id,
            'session_id': session_id,
            'ttft': ttft,
            'latency': result['latency'],
            'tokens': result['total_tokens'],
            'completion_tokens': result['completion_tokens']
        }
    return None

def run_concurrent_test(context_type, use_same_context=True):
    """동시 요청 테스트"""
    print(f"\n{'='*80}")
    print(f"🎯 테스트: {context_type}")
    print(f"{'='*80}")
    
    results = []
    start_time = time.time()
    
    with ThreadPoolExecutor(max_workers=CONCURRENT_REQUESTS) as executor:
        futures = []
        
        for i in range(CONCURRENT_REQUESTS):
            context = LONG_CONTEXT if use_same_context else DIFFERENT_CONTEXTS[i]
            session_id = f"session_{i+1}"
            
            future = executor.submit(single_request, i+1, context, session_id)
            futures.append(future)
        
        for future in as_completed(futures):
            result = future.result()
            if result:
                results.append(result)
                print(f"  ✓ 요청 {result['request_id']:2d} | Session: {result['session_id']:12s} | "
                      f"TTFT: {result['ttft']:.2f}s | Latency: {result['latency']:.2f}s")
    
    total_duration = time.time() - start_time
    
    return results, total_duration

def analyze_results(same_results, diff_results, same_duration, diff_duration):
    """결과 분석"""
    print(f"\n{'='*80}")
    print("📊 성능 분석 결과")
    print(f"{'='*80}\n")
    
    # TTFT 분석
    same_ttft = [r['ttft'] for r in same_results if r['ttft']]
    diff_ttft = [r['ttft'] for r in diff_results if r['ttft']]
    
    print("⏱️  TTFT (Time To First Token)")
    print("-" * 80)
    print(f"{'Metric':<20} {'같은 Prefix':>15} {'다른 Prefix':>15} {'개선율':>15}")
    print("-" * 80)
    
    for p in [50, 90, 95, 99]:
        same_p = np.percentile(same_ttft, p)
        diff_p = np.percentile(diff_ttft, p)
        improvement = ((diff_p - same_p) / diff_p * 100)
        print(f"P{p:<18} {same_p:>14.2f}s {diff_p:>14.2f}s {improvement:>14.1f}%")
    
    # Total Latency 분석
    same_latency = [r['latency'] for r in same_results]
    diff_latency = [r['latency'] for r in diff_results]
    
    print(f"\n⏱️  Total Latency")
    print("-" * 80)
    print(f"{'Metric':<20} {'같은 Prefix':>15} {'다른 Prefix':>15} {'개선율':>15}")
    print("-" * 80)
    
    for p in [50, 90, 95, 99]:
        same_p = np.percentile(same_latency, p)
        diff_p = np.percentile(diff_latency, p)
        improvement = ((diff_p - same_p) / diff_p * 100)
        print(f"P{p:<18} {same_p:>14.2f}s {diff_p:>14.2f}s {improvement:>14.1f}%")
    
    # Throughput 분석
    same_total_tokens = sum(r['tokens'] for r in same_results)
    diff_total_tokens = sum(r['tokens'] for r in diff_results)
    
    same_tps = same_total_tokens / same_duration
    diff_tps = diff_total_tokens / diff_duration
    
    print(f"\n🚀 Throughput (TPS)")
    print("-" * 80)
    print(f"{'Metric':<20} {'같은 Prefix':>15} {'다른 Prefix':>15} {'개선율':>15}")
    print("-" * 80)
    print(f"{'TPS':<20} {same_tps:>14.1f} {diff_tps:>14.1f} {((same_tps - diff_tps) / diff_tps * 100):>14.1f}%")
    print(f"{'Total Tokens':<20} {same_total_tokens:>15} {diff_total_tokens:>15}")
    print(f"{'Duration':<20} {same_duration:>14.1f}s {diff_duration:>14.1f}s")
    
    # 요약
    print(f"\n{'='*80}")
    print("🎯 핵심 요약")
    print(f"{'='*80}")
    
    same_ttft_p90 = np.percentile(same_ttft, 90)
    diff_ttft_p90 = np.percentile(diff_ttft, 90)
    ttft_improvement = ((diff_ttft_p90 - same_ttft_p90) / diff_ttft_p90 * 100)
    
    same_lat_p90 = np.percentile(same_latency, 90)
    diff_lat_p90 = np.percentile(diff_latency, 90)
    lat_improvement = ((diff_lat_p90 - same_lat_p90) / diff_lat_p90 * 100)
    
    tps_improvement = ((same_tps - diff_tps) / diff_tps * 100)
    
    print(f"✅ TTFT P90 개선: {ttft_improvement:.1f}%")
    print(f"✅ Latency P90 개선: {lat_improvement:.1f}%")
    print(f"✅ Throughput 향상: {tps_improvement:.1f}%")
    print(f"\n💡 Intelligent Routing & KV Cache가 같은 prefix 요청을 효율적으로 처리!")

if __name__ == "__main__":
    print("🚀 SageMaker HyperPod Inference 벤치마크")
    print(f"동시 요청: {CONCURRENT_REQUESTS}건")
    print(f"컨텍스트 길이: 약 4K 토큰\n")
    
    # 테스트 1: 같은 prefix
    same_results, same_duration = run_concurrent_test(
        "같은 Prefix 동시 요청", use_same_context=True
    )
    
    time.sleep(2)
    
    # 테스트 2: 다른 prefix
    diff_results, diff_duration = run_concurrent_test(
        "다른 Prefix 동시 요청", use_same_context=False
    )
    
    # 결과 분석
    analyze_results(same_results, diff_results, same_duration, diff_duration)
    
    print(f"\n{'='*80}")
    print("✅ 벤치마크 완료!")
    print(f"{'='*80}")
