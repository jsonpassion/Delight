# Delight

핀치로 3D 공간의 광원을 집어 옮기면 웹캠 영상이 그 조명으로 다시 렌더링되는 macOS 앱.
가까운 물체가 빛을 가리고, 피부에 반사광이 뜨고, 결과는 Zoom에 가상 카메라로 들어간다.

## 구조

Xcode 프로젝트는 `Delight/` 아래에 있고, 그 외 자산은 리포 루트에 있다.

```
Delight/                     Xcode 프로젝트
  Delight.xcodeproj
  Delight.entitlements
  Delight/                   앱 타깃 (Xcode 동기화 폴더)
    App/       엔진 오케스트레이터, 앱 진입점
    Capture/   AVFoundation → CVMetalTextureCache
    Depth/     DepthProvider (Metal 4 ML 기본 / Core ML 폴백)
    Geometry/  언프로젝션, 초점거리 추정, 깊이 안정화
    Relight/   LightRig, 렌더러
    Hand/      Vision 핸드포즈, 핀치 상태기계
    Sink/      FrameSink (프리뷰 / Syphon / CMIO)
    Shaders/   .metal
    UI/        SwiftUI
Tools/    probe, 벤치마크, 모델 페치 — 앱 타깃 밖이다(top-level 코드라 넣으면 안 됨)
Models/   gitignore. Tools/fetch_models.sh 로 재생성
docs/     리서치·아키텍처 문서
web/      랜딩 페이지 (GitHub Pages)
```

## 반드시 알아야 할 사실

**플랫폼은 macOS다.** 웹캠 캡처와 CMIO 가상카메라는 macOS 전용이다.
(이전 시도에서 iOS 템플릿으로 생성된 적이 있다 — `SDKROOT`가 `iphoneos`면 잘못된 것이다.)

**Xcode 동기화 폴더를 쓴다** (`objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup`).
`Delight/Delight/` 안에 파일을 만들면 pbxproj를 건드리지 않아도 타깃에 들어간다.
반대로 **top-level 코드가 있는 파일을 여기 두면 빌드가 깨진다** — `Tools/`에 둘 것.

**깊이 텐서에는 행 패딩이 있다.** `machineLearning` usage 때문에 `strides[1]`이 64바이트 정렬이라
f32 518열이 528 elem이 된다. 셰이더는 `depthRowStride`로 인덱싱해야 한다.

**macOS는 카메라 내부파라미터를 주지 않는다.** `videoFieldOfView`,
`cameraIntrinsicMatrixDelivery` 모두 `API_UNAVAILABLE(macos)`. 얼굴 기반으로 추정한다.

**레이마칭 thickness가 가장 위험한 파라미터다.** 크면 화면이 검게 죽고, 작으면 그림자가 안 생긴다.

**샌드박스는 꺼져 있어야 한다 (`ENABLE_APP_SANDBOX = NO`).** Xcode 템플릿 기본값이 YES라
entitlements 파일에 sandbox 키가 없어도 빌드 설정이 주입한다. 켜지면 컨테이너 밖
`Models/`를 못 읽어 `MTLLibraryErrorDomain "Invalid metal package"`로 나타난다.
(Syphon IOSurface 공유·CMIO 확장 설치도 샌드박스와 충돌한다 — 설계상 의도된 OFF다.)

## 성능 기준선 (M5, 518×392, 40회 median)

| 경로 | median |
|---|---|
| MTL4MachineLearningCommandEncoder | 15.42 ms |
| Core ML `.all` (ANE) | 20.78 ms |
| Core ML `.cpuOnly` | 45.10 ms |

여기서 크게 벗어나면 회귀를 의심한다.

**양자화는 검토 완료 — 현재 툴체인에서는 쓰지 않는다** (2026-08-19 실측).
INT8 mlpackage는 `metal-package-builder` 변환은 되지만 GPU에서 타임아웃(실행 불가),
Core ML 경로에서는 ANE 20.31ms로 F16과 동일해 이득이 없다. 파일 크기만 절반.
툴체인이 좋아지면 `Tools/quantize_model.py`와 `Tools/fetch_variants.sh`로 재검토한다.

## 빌드

```bash
xcodebuild -project Delight/Delight.xcodeproj -scheme Delight -configuration Debug build
```

Metal 셰이더에는 별도 툴체인이 필요하다: `xcodebuild -downloadComponent MetalToolchain`

## 작업 원칙

- **코드가 바뀌면 웹 문서도 같은 커밋에서 바뀐다.** `web-sync` 스킬/서브에이전트를 쓴다.
  커밋 전 `python3 Tools/check_html.py` 필수
- 각 단계는 **눈에 보이는 성과**로 끝낸다. 보이지 않는 진척은 진척이 아니다
- 데모 안전장치인 **마우스 폴백**을 항상 살려둔다
- 벤치 수치만으로 판단하지 않는다 — 결정적 입력을 넣고 출력을 확인한다
