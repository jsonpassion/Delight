---
name: run-delight
description: Delight 맥 앱을 빌드하고 실행해서 실제로 동작하는지 눈으로 확인할 때 사용. 빌드가 깨졌거나, 카메라가 안 잡히거나, 변경이 화면에 반영되는지 확인해야 할 때 읽는다.
---

# 빌드하고 실행하기

## 빌드

```bash
xcodebuild -project Delight/Delight.xcodeproj -scheme Delight -configuration Debug build
```

Metal 셰이더 컴파일에는 별도 툴체인이 필요하다. 없으면 이 에러가 난다:
`cannot execute tool 'metal' due to missing Metal Toolchain`

```bash
xcodebuild -downloadComponent MetalToolchain
```

## 실행

```bash
open ~/Library/Developer/Xcode/DerivedData/Delight-*/Build/Products/Debug/Delight.app
```

## 확인 순서

1. 창이 뜨고 **시작**을 누르면 카메라 프리뷰가 나온다 (P1)
2. 카메라 권한 프롬프트는 최초 1회 — 거부했다면 시스템 설정 → 개인정보 보호 및 보안 → 카메라
3. 우측 패널의 FPS가 도는지 확인. 0이면 캡처 콜백이 안 오는 것

## 흔한 실패

| 증상 | 원인 |
|---|---|
| 카메라 목록이 비어 있음 | 권한 미승인. 열거는 되지만 입력 생성에서 실패한다 |
| 프리뷰가 검은 화면 | `CVMetalTextureCache` 실패 또는 `kCVPixelBufferMetalCompatibilityKey` 누락 |
| 셰이더 링크 에러 | Metal 툴체인 미설치 |
| 빌드는 되는데 실행 즉시 종료 | entitlements와 Hardened Runtime 조합 확인 |
| "Invalid metal package" | `ENABLE_APP_SANDBOX`가 YES로 돌아갔는지 확인. 샌드박스가 컨테이너 밖 Models/ 읽기를 막는다. 시작 로그의 `[Delight] 모델 자가진단` 줄을 볼 것 |

## 데모 안전장치

손 인식이 실패해도 죽지 않도록 **마우스 폴백**이 있다(툴바의 입력 선택기).
데모 전에 반드시 마우스 모드가 동작하는지 확인한다.
