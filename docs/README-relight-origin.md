# Relight — 손으로 조명을 잡는 실시간 웹캠 리라이팅 (macOS)

핀치로 3D 공간의 광원을 집어 옮기면, 웹캠 영상이 그 조명으로 다시 렌더링된다.
가까운 물체가 빛을 가리고, 피부에 반사광이 뜨고, 결과는 Zoom에 가상 카메라로 들어간다.

> 리서치·검증 일자: **2026-08-19** · 검증 머신: **Apple M5 / macOS 26.1 / Xcode 26.0**

## 문서

| | |
|---|---|
| [00-feasibility](docs/00-feasibility.md) | 실현가능성, 실측 환경, **성능 벤치마크**, Zoom 진입 경로 3중화, 경쟁 분석, 리스크 |
| [01-architecture](docs/01-architecture.md) | 전체 파이프라인, 셰이더 수식, 레이마칭 그림자, 핀치 z 획득, 성능 예산 |
| [02-model-and-quality](docs/02-model-and-quality.md) | 모델 비교, **파인튜닝 필요 여부**, 증류 레시피, 평가 하네스, 재현 절차 |

## 핵심 발견 3가지

### 1. Metal 4 ML 인코더가 Core ML/ANE보다 빠르다 (실측)

| 경로 | median | fps |
|---|---|---|
| **MTL4MachineLearningCommandEncoder** (GPU 타임라인) | **15.42 ms** | **64.9** |
| Core ML `.all` (ANE) | 20.78 ms | 48.1 |
| Core ML `.cpuAndGPU` | 19.84 ms | 50.4 |
| Core ML `.cpuOnly` | 45.10 ms | 22.2 |

Depth Anything V2-small (518×392), Apple M5, 40회 median. 출력값 검증 완료(상수 아님, NaN 0).

레퍼런스로 삼은 TypeGPU 사례가 자랑한 "추론·라이팅·드로우가 같은 command encoder"는
macOS 26 + Metal 4에서 **네이티브로, dispatch 1회로** 얻어진다. 250개 커널을 손으로 짤 필요가 없다.

### 2. 핀치의 깊이(z)는 공짜다
손이 프레임 안에 있으므로 **깊이맵이 이미 손의 깊이를 갖고 있다.**
별도 센서도, 별도 모델도 필요 없다. 핀치 지점에서 같은 깊이맵을 샘플하면 끝이다.
그리고 같은 이유로 **손이 얼굴에 그림자를 드리운다** — 별도 구현 없이.

### 3. macOS에는 카메라 내부파라미터가 없다 (확인된 제약)
`videoFieldOfView`, `cameraIntrinsicMatrixDelivery` 모두 `API_UNAVAILABLE(macos)`.
초점거리는 **얼굴 랜드마크 + 평균 동공간거리(63mm)** 로 추정해야 한다. → [01-architecture §4](docs/01-architecture.md)

## 도구

```
tools/probe.swift        환경 전제조건 검증 (Metal4/텐서/카메라/Vision)
tools/bench_depth.swift  Core ML compute unit별 벤치
tools/bench_mtl4ml.swift Metal 4 ML 인코더 벤치 + 출력 검증
models/                  DepthAnythingV2SmallF16 (.mlpackage / .mlmodelc / .mtlpackage)
```

전부 `xcrun swiftc -O -o /tmp/x <file>` 로 바로 빌드·실행된다. 프로젝트 파일 불필요.

## 다음 단계 (Phase 계획)

각 단계는 **"눈에 보이는 성과"** 로 끝난다. 보이지 않는 진척은 진척이 아니다.

| Phase | 내용 | 끝났을 때 보이는 것 | 예상 |
|---|---|---|---|
| **P0** ✅ | 리서치·환경 검증·벤치마크 | 이 문서 + 15.4ms 실측 | 완료 |
| **P1** | 캡처 → Metal4 추론 → 깊이 시각화 창 | **웹캠 옆에 실시간 깊이맵이 뜬다** | 반나절 |
| **P2** | 언프로젝션 + 노멀 + 고정 광원 리라이팅 | **마우스로 조명을 끌면 얼굴 음영이 바뀐다** | 반나절 |
| **P3** | 레이마칭 그림자 + AO + 스펙큘러 | **조명을 옆으로 옮기면 코 그림자가 생긴다** | 하루 |
| **P4** | Vision 핸드포즈 + 핀치 + z 샘플링 | **손으로 조명을 잡아 앞뒤로 옮긴다** | 반나절 |
| **P5** | Syphon 싱크 → OBS → Zoom | **Zoom 화면에 나온다** | 반나절 |
| **P6** | 깊이 안정화(정합·시간필터·업샘플) | 떨림이 사라진다 | 하루 |
| **P7** | (선택) CMIO Camera Extension | OBS 없이 Zoom에 직접 | 하루+ |

**P2에서 반드시 마우스 폴백을 만들어 둔다.** 데모 중 손 인식이 실패해도 죽지 않는 유일한 보험이다.

## 열려 있는 결정

1. **출력 경로**: Syphon+OBS(안전) vs CMIO Camera Extension(제품). → 서명용 Apple Developer 계정 유무에 달림
2. **입력 카메라**: 내장(1552²@30) vs iPhone Continuity(1920×1440@**60**). 60fps 소스가 인터랙션 체감에 유리
3. **다중 광원**: 1개로 시작하되 `LightRig`는 배열로 설계 (키+필 2개면 품질이 확 오른다)
