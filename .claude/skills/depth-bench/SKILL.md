---
name: depth-bench
description: 깊이 추론 모델을 받고, 변환하고, 경로별로 벤치마크할 때 사용. 모델 교체를 검토하거나(INT8/해상도 축소/다른 모델), 추론이 느려졌을 때 원인을 찾거나, Core ML과 Metal 4 ML 경로 중 무엇을 쓸지 결정할 때 읽는다.
---

# 깊이 모델 받기 · 변환 · 벤치

## 모델 받기

```bash
./Tools/fetch_models.sh
```

`apple/coreml-depth-anything-v2-small`(Apache-2.0)을 받아 `.mlmodelc`와 `.mtlpackage`까지 만든다.
`Models/`는 gitignore되어 있다 — 142MB이고 재생성 가능하다.

## 벤치 실행

```bash
xcrun swiftc -O -o /tmp/bench  Tools/bench_depth.swift  && /tmp/bench  Models/DepthAnythingV2SmallF16.mlmodelc
xcrun swiftc -O -o /tmp/bench4 Tools/bench_mtl4ml.swift && /tmp/bench4 Models/DepthAnythingV2Small.mtlpackage
xcrun swiftc -O -o /tmp/probe  Tools/probe.swift        && /tmp/probe
```

## M5 기준선 (518×392, 40회 median)

| 경로 | median | fps |
|---|---|---|
| MTL4MachineLearningCommandEncoder | **15.42 ms** | 64.9 |
| Core ML `.all` (ANE) | 20.78 ms | 48.1 |
| Core ML `.cpuAndGPU` | 19.84 ms | 50.4 |
| Core ML `.cpuOnly` | 45.10 ms | 22.2 |

**이 수치에서 크게 벗어나면 회귀를 의심한다.**

## 더 빠르게 만들어야 할 때 — 이 순서로

학습에 손대기 전에 전부 소진한다. 순서를 지키면 대부분 여기서 끝난다.

1. **INT8 / palettized 변형**(`...F16INT8`, `...F16P6`, `...F16P8`) — 다운로드만 하면 10분
2. **입력 해상도 축소** 518×392 → 448×336 → 392×294.
   깊이는 저해상도에 놀랍게 관대하다. 어차피 업샘플한다
3. **변환 그래프의 f32 고정을 f16으로** 낮출 수 있는지 coremltools 재변환으로 확인
4. 그래도 부족하면 모델 교체(ZipDepth 6.1M) 또는 증류

## 어느 경로를 쓸 것인가

기본은 **Metal 4 ML**(빠르고 CPU 동기화 0).
GPU가 렌더로 포화되면 **Core ML/ANE**로 바꾼다 — 20.8ms지만 GPU 예산을 전혀 쓰지 않는다.
`DepthProvider` 프로토콜이 이 교체를 위해 존재한다.

## 참고

- 모델 비교·증류 레시피: `docs/02-model-and-quality.md`
