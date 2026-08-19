# 실현가능성 검토 — 손 핀치로 조명을 움직이는 macOS 실시간 리라이팅

> 작성 2026-08-19 · 이 문서의 수치는 **이 맥에서 직접 측정한 값**이다(추정치는 명시함).

## 0. 한 줄 결론

가능하다. 그리고 이 머신(M5 + macOS 26.1)은 **이 문제를 풀기에 현시점 가장 유리한 조합**이다.
단, 문제를 두 개로 분리해야 한다.

| | 문제 | 난이도 | 실패 리스크 |
|---|---|---|---|
| **A** | 실시간 리라이팅 엔진 (깊이 → 재조명 → 레이마칭 그림자) | 기술적으로 높음 | 품질(그림자 아티팩트, depth 떨림) |
| **B** | 그 결과물을 Zoom에 카메라로 꽂기 | 기술적으로 낮음 | **행정적으로 높음** (서명·공증·시스템확장 승인·재부팅) |

B가 A보다 사람을 더 많이 죽인다. 그래서 **엔진과 출력을 완전히 분리**하고, 출력 경로를 3중으로 준비한다.

---

## 1. 실측 환경 (`relight/tools/probe.swift` 실행 결과)

```
device            : Apple M5  (10코어: P4/E6, 24GB 통합메모리)
GPU families      : Apple7~Apple10, Metal3, Metal4        ← Metal 4 지원
recommended max WS: 18,186 MB
macOS             : 26.1 (25B78) / Xcode 26.0 / SDK 26.0 / Swift 6.2
```

**Metal 4 ML 경로 — 전부 존재하고 동작함**

```
metal-package-builder            : /Applications/Xcode.app/.../usr/bin/metal-package-builder
MTL4MachineLearningCommandEncoder: SDK 헤더 존재 (macos 26.0+)
MTL4MachineLearningPipeline      : 존재
MTLTensor                        : 존재
buffer-backed tensor [ML|compute]: 생성 성공  ← 셰이더가 추론 출력을 직접 읽을 수 있다
MTL4CommandQueue / MTL4Compiler  : 생성 성공
```

**카메라 (5종 감지)**

| 장치 | 최대 포맷 |
|---|---|
| MacBook Pro 내장 | 1552×1552 @30 (420v) |
| LG UltraFine | 1920×1080 @30 |
| **iPhone (Continuity)** | **1920×1440 @60** ← 데모용 최적 |
| Desk View ×2 | 1920×1440 @30 |

**Vision 프레임워크**

```
DetectHumanHandPoseRequest : OK (revision1, maxHands 설정 가능)
GeneratePersonSegmentation : OK (revision1)
DetectFaceLandmarksRequest : OK (revision3)
```

### ⚠️ 확인된 하드 제약 — macOS에는 카메라 내부파라미터가 없다

```
AVCaptureDeviceFormat.videoFieldOfView               → API_UNAVAILABLE(macos)
AVCaptureConnection.cameraIntrinsicMatrixDelivery*   → API_UNAVAILABLE(macos)
```

둘 다 iOS 전용이다. 즉 **초점거리(fx, fy)를 시스템이 알려주지 않는다.**
깊이맵을 3D로 언프로젝션하려면 fx가 필요한데 이 값이 없다. 대응은 [01-architecture](01-architecture.md) §4에.

---

## 2. 추론 성능 실측 — 여기가 이 프로젝트의 핵심 발견

모델: `apple/coreml-depth-anything-v2-small` F16 (ViT-S/24.8M, 입력 518×392 BGRA, 출력 518×392 f32 단일채널 **이미지 타입**)

### 2-1. Core ML 경로 (`tools/bench_depth.swift`, 40회 median)

| Compute Unit | median | p10 / p90 | fps |
|---|---|---|---|
| `.all` (ANE 우선) | **20.78 ms** | 20.70 / 20.93 | 48.1 |
| `.cpuAndNeuralEngine` | 20.74 ms | 20.66 / 20.86 | 48.2 |
| `.cpuAndGPU` | 19.84 ms | 18.98 / 21.72 | 50.4 |
| `.cpuOnly` | 45.10 ms | 44.82 / 45.66 | 22.2 |

### 2-2. Metal 4 ML 인코더 경로 (`tools/bench_mtl4ml.swift`, 40회 median)

```bash
xcrun metal-package-builder -ml DepthAnythingV2SmallF16.mlpackage -o DepthAnythingV2Small.mtlpackage
# → Created metal package (47MB, 내부는 library.mpsgraphpackage)
```

| 경로 | median | p10 / p90 | fps |
|---|---|---|---|
| **MTL4MachineLearningCommandEncoder** | **15.42 ms** | 14.99 / 16.41 | **64.9** |

출력 검증(결정적 입력 주입 후 읽기): `min 0.0000 max 1.0000 mean 0.3146 NaN 0/206976`
→ 상수가 아니고 NaN도 없다. **네트워크가 실제로 실행된다.**

### 2-3. 이게 왜 중요한가

Core ML/ANE 대비 **26% 빠르고**, 더 중요하게는 **CPU 동기화가 0**이다.
추론·라이팅·드로우가 하나의 `MTL4CommandBuffer` 안에서 GPU 타임라인으로 이어진다.
레퍼런스로 삼은 TypeGPU 사례("448², ~8ms, ~250 dispatch, M4 Pro, 추론·라이팅·드로우가 같은 command encoder")가
말한 그 성질을, **네이티브에서 dispatch 1회로** 얻는다. 250개 커널을 손으로 짤 필요가 없다.

> 정직하게: 절대시간은 아직 그쪽(8ms)이 빠르다. 픽셀 수는 거의 같다(448²=200,704 vs 518×392=203,056).
> 격차의 원인 후보는 ① 그쪽 모델이 ViT-S보다 작음 ② 더 공격적인 양자화 ③ MPSGraph 변환 비효율.
> 대응책은 [02-model-and-quality](02-model-and-quality.md) §3에 정리했다. **지금 수치로도 30fps 파이프라인은 성립한다.**

### 2-4. 검증 과정에서 확인된 Metal 4 실무 제약 (문서에 잘 안 나옴)

1. `MTLDevice.makeTensor(descriptor:)`는 **strides가 반드시 nil**이어야 한다.
   셰이더가 읽을 buffer-backed 텐서는 `MTLBuffer.makeTensor(descriptor:offset:)`로 만든다.
2. `MTLTensorUsageMachineLearning`이면 **`strides[1]`이 64바이트 정렬**이어야 한다.
   518 f32 = 2072B → 2112B(528 elem)로 패딩된다. **셰이더는 행 패딩을 반드시 계산에 넣어야 한다.**
3. `metal-package-builder`로 변환된 그래프는 **f32 입출력을 기대**한다(f16 텐서를 물리면 MPSGraph assert).
4. 커밋 피드백 핸들러를 쓰려면 `MTL4CommandQueueDescriptor.feedbackQueue`를 지정해야 한다.
   지정 안 하면 콜백이 영영 안 온다. 동기화는 `MTLSharedEvent`가 더 단순하고 확실하다.
5. Metal 4는 자동 레지던시가 없다. 버퍼·힙을 `MTLResidencySet`에 넣고 큐에 붙여야 한다.
6. mtlpackage의 함수 이름은 `"main"`이다 (`library.functionNames == ["main"]`).

---

## 3. Zoom에 꽂는 경로 — 3중 준비

### 경로 1: CMIO Camera Extension (정식·제품용)

macOS 12.3부터 DAL 플러그인을 대체한 유일한 공식 경로. OBS 28+가 쓰는 그 방식이고,
Zoom·Teams·Meet·Safari에서 **평범한 카메라 장치로 보인다.** 기술적으로는 검증된 길이다.

구조:
```
컨테이너 앱 (엔진: 캡처→추론→리라이팅)
   │  IOSurface 기반 sink stream (1080p60 zero-copy)
   │  제어는 Darwin notification(CFNotificationCenter) 또는 XPC
   ▼
Camera Extension (.app/Contents/Library/SystemExtensions/)
   ▼  CMIOExtensionStream
CoreMediaIO → Zoom의 카메라 목록에 등장
```

행정 요구사항(전부 충족해야 함):
- Developer ID 서명 + notarization + hardened runtime
- `com.apple.developer.system-extension.install` entitlement
- **앱이 `/Applications`에 있어야** 시스템확장 설치가 승인됨
- 사용자가 시스템 설정에서 승인 + **대개 재부팅 1회**
- 개발 중 우회는 `systemextensionsctl developer on` → **SIP 비활성화 필요**(복구모드 재부팅)

개발 루프의 함정:
- 확장은 별도 사용자 계정으로 실행 → 컨테이너 앱과 다른 프로세스
- **세션 중 확장 라이브 교체 불가**(재부팅 필요). 코드 한 줄 고칠 때마다 재부팅은 치명적
- Xcode 콘솔 디버깅 불가 → Console.app 통합로그 + lldb attach

### 경로 2: Syphon → OBS 가상카메라 (개발·데모용 1순위) ★

우리 앱은 **Syphon 서버로 텍스처만 publish**한다(IOSurface, zero-copy).
OBS의 Syphon Client 소스가 받고, OBS의 가상카메라가 Zoom으로 송출한다.

```
우리 앱 ──Syphon(IOSurface)──▶ OBS ──OBS Virtual Camera──▶ Zoom
```

장점이 압도적이다:
- **서명·공증·시스템확장·재부팅 전부 불필요.** OBS의 확장은 이미 서명·공증되어 있다
- Syphon 서버 붙이는 데 반나절이면 충분하고, 실패해도 엔진에 영향 없음
- 데모 중 OBS가 죽어도 앱 자체 프리뷰 창은 살아있음
- Apple Silicon 유니버설 빌드 지원 확인됨

단점: 사용자가 OBS를 깔아야 함 → **제품이 아니라 데모/개발 경로**로만 쓴다.

### 경로 3: Zoom 화면공유 (최후 보루)

앱 창을 화면공유. 30초 안에 "작동하는 걸 보여주기"는 성립한다. 준비 비용 0.

### 권장 설계

```swift
protocol FrameSink {                 // 엔진은 이 인터페이스만 안다
    func submit(_ texture: MTLTexture, pts: CMTime)
}
struct PreviewSink: FrameSink { }    // 항상 켜둠 (앱 창)
struct SyphonSink:  FrameSink { }    // 경로 2
struct CMIOSink:    FrameSink { }    // 경로 1 (나중에)
```

엔진은 싱크가 뭔지 몰라야 한다. 이러면 경로 1이 서명 문제로 막혀도 프로젝트가 안 죽는다.

### Zoom 쪽 실패 모드 체크리스트

- **실행 순서**: 가상카메라 앱을 먼저 켜고 Zoom을 나중에 켠다. Zoom은 시작 시 한 번만 장치를 스캔한다
- 시스템 설정 → 개인정보 보호 및 보안 → 카메라: **우리 앱과 Zoom 둘 다** 허용
- 시스템확장 승인 프롬프트를 놓쳤으면 "개인정보 보호 및 보안" 하단에 차단 메시지가 남아 있다 → 허용 후 재부팅
- 설치·업데이트 후에는 완전 재부팅이 가장 확실한 해결책

---

## 4. 경쟁·선행 사례 (차별점 확인)

| | 무엇 | 우리와 다른 점 |
|---|---|---|
| macOS Studio Light | 시스템 비디오 이펙트. 얼굴을 밝히고 배경을 어둡게 | **조명 위치를 못 옮긴다.** 프리셋 한 개 |
| NVIDIA Broadcast Virtual Key Light | 얼굴 자동 리라이팅 | NVIDIA GPU 전용. 역시 **위치 제어 없음**, 손 인터랙션 없음 |
| SwitchLight (Beeble) | intrinsic 분해 기반 고품질 PBR 리라이팅 | 오프라인/포스트프로덕션 급. 실시간 아님 |
| LiveLight (TOG 2026) | 디퓨전 기반 실시간 스트리밍 리라이팅, 3D 점광원 제어 | **15.78 fps / 0.253s 지연**. 디퓨전이라 무겁고 지연이 큼 |
| IC-Light 등 디퓨전 계열 | 고품질 리라이팅 | 스펙큘러 아티팩트·색 시프트 보고됨. 실시간 불가 |

**빈 칸이 명확하다: 실시간 + 위치 제어 + 손 인터랙션 + 맥 네이티브.**
LiveLight가 방향은 같지만 디퓨전이라 15fps/250ms다. 우리는 물리 기반 렌더링이라 **60fps/16ms**를 노린다.
품질은 그쪽이 위, 지연·상호작용성은 우리가 위 — 그리고 "손으로 조명을 잡는" 경험은 지연이 곧 품질이다.

---

## 5. 리스크 등록부

| # | 리스크 | 영향 | 대응 |
|---|---|---|---|
| R1 | 시스템확장 서명·승인 실패 | Zoom 진입 불가 | 경로 2(Syphon+OBS)를 기본으로. 경로 1은 후순위 |
| R2 | depth 프레임 간 떨림 → 조명이 펄럭임 | 데모 품질 치명 | 배경 기준 affine 정합 + edge-stopping 시간필터 (§01-arch §5) |
| R3 | 레이마칭 두께(thickness) 오설정 → 화면이 검게 죽음 | 치명 | person matte 기반 두께 프라이어 + 상한 클램프 |
| R4 | 초점거리 미상 → 라이트 z 이동이 부자연스러움 | 중간 | 얼굴 기반 캘리브레이션 + 사용자 슬라이더 폴백 |
| R5 | 핀치 오검출/손 유실 | 중간 | 히스테리시스 + 손크기 보조신호 + 마지막 위치 홀드 |
| R6 | GPU 예산 초과(추론 15ms + 렌더) | 중간 | 추론 30Hz / 렌더 60Hz 분리, half-res 레이마칭 |

