# Delight

**손으로 잡는 조명.** 핀치로 3D 공간의 광원을 집어 옮기면 웹캠 영상이 그 조명으로 다시 렌더링됩니다.
가까운 물체가 빛을 가리고, 피부에 반사광이 뜨고, 결과는 Zoom에 가상 카메라로 들어갑니다.

> *Grab a light with your hand.* Real-time monocular-depth relighting for macOS —
> pinch to move a 3D point light through your webcam scene, with ray-marched occlusion.

🔗 **[랜딩 페이지에서 직접 조명을 끌어보세요](https://jsonpassion.github.io/Delight/)**

---

## 왜 만드나

| 기존 | 한계 |
|---|---|
| macOS Studio Light | 조명 **위치를 못 옮긴다.** 프리셋 한 개 |
| NVIDIA Broadcast Virtual Key Light | NVIDIA GPU 전용. 역시 위치 제어 없음 |
| SwitchLight (Beeble) | 고품질이지만 포스트프로덕션 급 |
| LiveLight (TOG 2026) | 방향은 같지만 디퓨전이라 15.78fps · 0.253s 지연 |

**실시간 + 위치 제어 + 손 인터랙션 + 맥 네이티브** — 이 조합이 아직 없습니다.
그리고 손으로 조명을 잡는 경험에서는 지연이 곧 품질입니다.

## 측정값

Apple M5, Depth Anything V2-small, 518×392, 40회 median:

| 추론 경로 | median | fps |
|---|---|---|
| **`MTL4MachineLearningCommandEncoder`** | **15.42 ms** | **64.9** |
| Core ML `.all` (Neural Engine) | 20.78 ms | 48.1 |
| Core ML `.cpuAndGPU` | 19.84 ms | 50.4 |
| Core ML `.cpuOnly` | 45.10 ms | 22.2 |

Metal 4 ML 인코더가 ANE보다 26% 빠르고, 무엇보다 **CPU 동기화가 0**입니다 —
추론·라이팅·드로우가 하나의 커맨드 버퍼 안에서 GPU 타임라인으로 이어집니다.

## 구조

```
Delight/Delight/  앱 타깃 (Xcode 동기화 폴더)
  App/       엔진 오케스트레이터        Hand/      Vision 핸드포즈, 핀치
  Capture/   AVFoundation → Metal      Sink/      프리뷰 / Syphon / CMIO
  Depth/     Metal 4 ML · Core ML      Shaders/   .metal
  Geometry/  언프로젝션, 깊이 안정화     UI/        SwiftUI
  Relight/   LightRig, 렌더러
Tools/       probe · 벤치마크 · 모델 페치
docs/        리서치 · 아키텍처 문서
web/         랜딩 페이지 (GitHub Pages)
```

## 시작하기

요구사항: **macOS 26+**, Apple Silicon, Xcode 26+

```bash
xcodebuild -downloadComponent MetalToolchain   # Metal 셰이더 컴파일용 (최초 1회)
./Tools/fetch_models.sh                        # 깊이 모델 받기 + 변환 (~49MB)
xcodebuild -project Delight/Delight.xcodeproj -scheme Delight build
```

벤치마크만 돌려보려면:

```bash
xcrun swiftc -O -o /tmp/probe Tools/probe.swift && /tmp/probe
xcrun swiftc -O -o /tmp/bench4 Tools/bench_mtl4ml.swift && /tmp/bench4 Models/DepthAnythingV2Small.mtlpackage
```

## 문서

| | |
|---|---|
| [00-feasibility](docs/00-feasibility.md) | 실현가능성, 실측 환경, 벤치마크, Zoom 진입 경로 3중화, 리스크 |
| [01-architecture](docs/01-architecture.md) | 파이프라인, 셰이더 수식, 레이마칭, 핀치 z 획득, 성능 예산 |
| [02-model-and-quality](docs/02-model-and-quality.md) | 모델 비교, 파인튜닝 판단, 증류 레시피, 평가 하네스 |

## 진행 상황

- [x] **P0** 리서치 · 환경 검증 · 벤치마크
- [x] **P1** 캡처 → Metal 4 추론 → 깊이 시각화 · [파이프라인 해부](https://jsonpassion.github.io/Delight/pipeline.html)
- [x] **P2** 언프로젝션 + 노멀 + 마우스로 조명 끌기
- [x] **P3** 레이마칭 그림자 + 스펙큘러 + 핀치로 조명 잡기
- [x] **P4** AO · Vision 세그멘테이션 · 화질 개선(해상도·sRGB·후광)
- [x] **P5** 깊이 안정화 (edge-stopping 시간필터 · 배경 앵커 affine 정합) — 플리커 8배 감소
- [ ] **P6** Syphon → OBS → Zoom
- [ ] **P7** CMIO Camera Extension

## 프라이버시

영상 처리는 전부 로컬에서 일어납니다. 프레임은 이 맥을 벗어나지 않고, 네트워크로 나가지 않습니다.

## 라이선스

MIT. 깊이 모델은 [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small) (Apache-2.0)를 사용합니다.
