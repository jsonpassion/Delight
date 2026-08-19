# 모델 선택과 "파인튜닝이 필요한가"

## 1. 결론부터

**1단계에서는 파인튜닝이 필요 없다.** 속도는 이미 충분하고(실측 15.4ms/65fps),
병목은 속도가 아니라 **품질 3종**이다. 그리고 그 셋 중 둘은 학습 없이 해결된다.

| 품질 문제 | 학습이 필요한가 | 1차 대응 |
|---|---|---|
| (a) 얼굴 미세 기복이 뭉개짐 → 조명이 평평 | **아니오** | 루마 고주파 → 노멀 디테일 주입 (셰이더 3줄) |
| (b) 프레임 간 플리커 | **아니오** | edge-stopping 시간필터 + 배경 앵커 affine 정합 |
| (c) 절대 스케일 부재 | 부분적으로 | 얼굴 기반 캘리브레이션 + 배경 앵커 |

**"파인튜닝"보다 먼저 할 일은 "증류(distillation)"이고, 그것도 2단계 이후다.**
해커톤/MVP 일정이라면 학습에 손대는 순간 진다. 먼저 위 3줄짜리 대응을 다 쓰고, 그래도 부족하면 §3으로 간다.

---

## 2. 모델 후보 비교

| 모델 | 종류 | 크기 | 라이선스 | 성능 | 판정 |
|---|---|---|---|---|---|
| **Depth Anything V2-small** | 상대(affine-invariant inverse) | ViT-S 24.8M / f16 49.8MB | Apache-2.0 | **M5 실측: Metal4 15.4ms / ANE 20.8ms** (레퍼런스: M3 Max ANE 24.6ms, M1 Max 32.8ms) | ★ **시작점.** Apple 공식 Core ML 배포가 있어 변환 리스크 0 |
| Depth Anything V2-small INT8/P6/P8 | 동일 | 더 작음 | Apache-2.0 | 미측정 | 속도가 부족하면 다음 카드 |
| **Depth Anything 3-small** | 단안+멀티뷰 통합 (2025-11 공개) | small 계열 | 확인 필요 | ONNX 커뮤니티 변환 존재 | 품질 업 기대. **Core ML 변환을 직접 해야 함** → 2순위 |
| ZipDepth (2026) | 경량 zero-shot | **6.1M** | 확인 필요 | "real-time", Apple NPU 수치 미공개 | 초저지연이 필요할 때의 카드 |
| **Apple Depth Pro** | **메트릭 + 초점거리 추정** | 1536², mlpackage 1.9GB | Apple | 0.3s/장 (V100) | 실시간 불가. **교사·캘리브레이터 전용** ★ |
| Video Depth Anything (CVPR'25) | 시간 일관성 SOTA | DAv2 + spatio-temporal head | — | 엣지 실시간 어려움 | **시간일관 pseudo-label 교사** |

### Depth Pro의 진짜 쓸모 — 이중 레이트
Depth Pro는 실시간이 안 되지만 **초점거리를 추정한다.** 그리고 웹캠 씬은 **배경이 정적이다.**

```
0.2 Hz : Depth Pro로 배경 깊이 + fx 추정 → 앵커로 고정
30 Hz  : DAv2-small로 사람/손만 추적 → 앵커에 정합
```
이러면 §4의 절대 스케일 문제와 §01-arch §4의 초점거리 문제가 동시에 풀린다.
**이건 이 도메인에서만 되는 반칙에 가까운 트릭이다.** (일반 씬은 배경이 안 정적이라 못 쓴다)

---

## 3. 그래도 학습을 한다면 — 순서

### 3-1. 먼저 확인할 것: 속도 격차의 원인
레퍼런스 사례(TypeGPU, 448², ~8ms, M4 Pro)와 우리(518×392, 15.4ms, M5) 사이엔 약 2배 격차가 있다.
픽셀 수는 같으므로 **모델 자체가 다르거나 양자화 수준이 다르다.** 학습에 손대기 전에 이 순서로 확인한다:

1. INT8 / palettized(P6, P8) 변형 벤치 — 다운로드만 하면 되고 10분이면 끝난다
2. 입력 해상도 축소: 518×392 → 448×336 또는 392×294. **깊이는 저해상도에 놀랍게 관대하다** (어차피 업샘플한다)
3. `metal-package-builder` 변환 그래프의 f32 고정을 f16으로 낮출 수 있는지 (coremltools 재변환)
4. 그래도 안 되면 그때 모델 교체(ZipDepth 6.1M) 또는 증류

### 3-2. 증류 레시피 (2단계, 학습이 정말 필요할 때)
GT 깊이는 필요 없다. DAv2 자신이 이 레시피로 만들어졌다(교사가 62M 프레임에 pseudo-label).

```
교사 : Depth Pro (샤프·메트릭) 또는 Video Depth Anything (시간일관)
      ↓ pseudo-label
데이터: 웹캠 도메인 — 정면 상반신, 0.4~1.2m, 실내 조명, 손이 프레임에 들어오는 장면 포함
      자체 녹화 + 공개 토킹헤드 데이터셋 (라이선스 확인 필수)
학생 : DAv2-small을 448² 고정 입력으로 파인튜닝
손실 : L1(로그공간) + 특징정렬(DINOv2 의미 보존) + 시간 gradient 일관성
```

**도메인을 좁히는 게 핵심이다.** 범용 모델은 실내·실외·근거리·원거리를 다 커버하느라 용량을 낭비한다.
"웹캠 앞 상반신"만 하면 같은 24.8M으로 훨씬 선명해지고, 더 작은 모델로도 내려갈 수 있다.

### 3-3. 시간 일관성이 정말 문제라면
후처리 필터로 안 되면 교사를 Video Depth Anything으로 바꿔 **시간일관 pseudo-label**을 만들고 증류한다.
학생은 여전히 프레임 독립 추론이지만, 학습으로 "떨지 않는 법"을 배운다. 추론 비용은 그대로다.

---

## 4. 품질 평가 하네스 (30분이면 만든다, 반드시 먼저 만들 것)

파라미터를 손으로 돌리면서 "이게 나아진 건가?"를 눈으로 판단하면 반드시 헤맨다.

**고정 테스트 클립 5종 × 10초**
1. 정면 기본 2. 측면 45° 3. 역광(창 앞) 4. 저조도 5. 손이 프레임에 들어옴

**지표**
| 지표 | 계산 | 목표 |
|---|---|---|
| 플리커 | 연속 프레임 깊이차의 중앙값(정적 배경 영역만) | 낮을수록 |
| 실루엣 정합 | person matte 경계에서 깊이 gradient 크기 | 높을수록(경계가 선명) |
| 스케일 드리프트 | 10초간 배경 앵커의 a,b 변동폭 | 낮을수록 |
| 그림자 일관성 | 조명을 원형 궤적으로 돌릴 때 그림자 방향 오차 | 육안 A/B |

파라미터를 바꿀 때마다 같은 클립을 돌려 수치를 비교한다. **회귀를 잡는 게 목적이지 절대값이 목적이 아니다.**

---

## 5. 재현 절차

```bash
# 1) 모델 받기 (49MB)
M=DepthAnythingV2SmallF16.mlpackage
B=https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main
mkdir -p relight/models/$M/Data/com.apple.CoreML/weights
for f in "$M/Manifest.json" "$M/Data/com.apple.CoreML/model.mlmodel" "$M/Data/com.apple.CoreML/weights/weight.bin"; do
  curl -sL "$B/$f" -o "relight/models/$f"
done
```

```bash
# 2) Core ML 경로 벤치 (compute unit별)
xcrun coremlcompiler compile relight/models/DepthAnythingV2SmallF16.mlpackage relight/models/
xcrun swiftc -O -o /tmp/bench relight/tools/bench_depth.swift && /tmp/bench relight/models/DepthAnythingV2SmallF16.mlmodelc
```

```bash
# 3) Metal 4 ML 인코더 경로로 변환 + 벤치
xcrun metal-package-builder -ml relight/models/DepthAnythingV2SmallF16.mlpackage -o relight/models/DepthAnythingV2Small.mtlpackage
xcrun swiftc -O -o /tmp/bench4 relight/tools/bench_mtl4ml.swift && /tmp/bench4 relight/models/DepthAnythingV2Small.mtlpackage
```

```bash
# 4) 환경 전제조건 재확인
xcrun swiftc -O -o /tmp/probe relight/tools/probe.swift && /tmp/probe
```
