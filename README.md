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

앱이 실제로 쓰는 시간은 이와 별개입니다. 카메라 네이티브 1552×1552 출력 · 캡처 30.0 fps에서
한 프레임이 **GPU 평균 23.7 ms**(범위 21.0~33.1)입니다 — 30 fps 예산 33.3 ms 안입니다.

이 값은 **발열 구간을 포함한 세션**의 것이라 이전에 기록한 22.1 ms와 단순 비교하면 안 됩니다.
같은 세션 안에서 반복 실행만으로 gpu가 21 ms대에서 30 ms대로 밀렸습니다 —
그래서 변경의 효과는 앞뒤 절대값이 아니라 **한 세션 안의 A/B 교차 측정**으로만 판정합니다
([§09-4](https://jsonpassion.github.io/Delight/pipeline.html#rejected)).

## 어떻게 동작하나

```
C0 전처리 → ML 추론 → C1 안정화 → C3 높이장 재투영 → C4 AO(높이장 해상도) → C5 리라이팅(POM 레이마칭)
```

여섯 스테이지가 **하나의 커맨드 버퍼** 안에 있고 CPU 동기화가 없습니다.
(C2는 비어 있습니다 — 깊이 시각화 패스를 지웠습니다.)

씬을 3D 점구름이 아니라 **2D 높이장**으로 다룹니다. 그러면 각 픽셀에서 광원으로 향하는 광선이
**텍스처 공간에서 직선**이라 스텝마다 화면에 재투영할 필요가 없습니다 —
시차 폐색 매핑(POM)이 쓰는 성질 그대로입니다. 스텝당 나눗셈 2회 + 텍스처 페치 2회가 페치 1회가 됩니다.

노멀도 이웃 높이차로 구하므로 뷰공간 위치를 복원하지 않습니다.
높이는 uv와 같은 [0,1]로 정규화하고, 실제 종횡비는 `heightToUV` 비율이 따로 들고 있습니다.
자세한 것은 [파이프라인 해부 §06-8](https://jsonpassion.github.io/Delight/pipeline.html#heightfield)에 있습니다.

## 구조

```
Delight/Delight/  앱 타깃 (Xcode 동기화 폴더)
  App/       엔진 오케스트레이터        Hand/      Vision 핸드포즈, 핀치
  Capture/   AVFoundation → Metal      Sink/      프리뷰 / Syphon / CMIO
  Depth/     Metal 4 ML · Core ML      Shaders/   .metal (HeightField · Relight)
  Geometry/  깊이 안정화, 초점거리 추정   UI/        SwiftUI
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

화면에 있는 것은 **시작 버튼, 송출 토글, 지금 조명을 잡고 있는지 알려주는 한 줄**이 전부입니다.
파라미터 슬라이더는 없습니다 — 튜닝이 끝난 값은 상수입니다.
손 추적이 안 되는 환경에서는 **마우스 드래그가 토글 없이 항상 동작합니다.**

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
- [x] **P6** Syphon → OBS → Zoom (서명·공증·재부팅 없는 경로)
- [ ] **P7** CMIO Camera Extension — **부분 완료.** 확장 타깃 빌드 · 서명 · 앱 번들 임베드까지 됩니다.
  설치는 조건부입니다: Developer ID 서명 + 공증, 또는 SIP를 끄고 개발자 모드.
  그 조건이 없는 환경에서는 P6(Syphon → OBS) 경로가 그대로 동작합니다
- [x] **다듬기** 피부 스펙큘러를 구 면광원 + 이중 로브로 · 가려진 관절 판정 · UI 제거(2955 → 2531줄)
  · 캡처 경로에서 MainActor 제거
- [x] **안정성** `CVMetalTextureCacheFlush` 누락으로 IOSurface가 쌓여 **맥이 재부팅된 사고** 수정 ·
  메모리 감시(10초 · 4GB) · `@Observable`은 값이 바뀔 때만 · 세그멘테이션 기본 OFF(`--matte`로 켬).
  2분 8초 연속 실행에서 크래시 0 · RSS 324 → 131MB ·
  [§07-3](https://jsonpassion.github.io/Delight/pipeline.html#reboot)
- [x] **재구성** 높이장 아키텍처 — 텍스처 공간 POM 레이마칭(2531 → 2615줄) ·
  [§06-8](https://jsonpassion.github.io/Delight/pipeline.html#heightfield)
- [x] **성능 회수** AO를 높이장 해상도(518×392)의 전용 커널로 이동 —
  gpu 평균 22.1ms · 최저 16.7ms (직전 22.6~24.3ms) ·
  놓아둔 광원을 손으로 가리면 빛무리만 사라지도록 수정 ·
  [§06-8](https://jsonpassion.github.io/Delight/pipeline.html#heightfield)
- [x] **기각** 레이마칭 계층화(coarse → fine) — 구현 후 같은 세션 교차 측정에서
  균일 29.8ms vs 계층 31.0ms로 **오히려 느려** 되돌렸습니다.
  워프 발산 · 의존적 텍스처 페치 · 캐시 지역성이 이유입니다.
  A/B 스위치까지 지우고 셰이더 주석에 측정값을 남겼습니다 ·
  [§09-4](https://jsonpassion.github.io/Delight/pipeline.html#rejected)
- [ ] **남은 회수** 높이장 joint bilateral 업샘플 · 도메인 증류 ·
  [§12](https://jsonpassion.github.io/Delight/pipeline.html#next)

## 프라이버시

영상 처리는 전부 로컬에서 일어납니다. 프레임은 이 맥을 벗어나지 않고, 네트워크로 나가지 않습니다.

## 라이선스

MIT. 깊이 모델은 [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small) (Apache-2.0)를 사용합니다.
