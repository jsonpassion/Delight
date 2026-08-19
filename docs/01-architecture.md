# 파이프라인 아키텍처

> 목표: 웹캠 프레임을 2.5D 씬으로 복원하고, 손 핀치로 잡은 3D 점광원으로 재조명한다.
> 가까운 물체가 빛을 가리고(레이마칭 그림자), 피부에 반사광이 뜨고, 60fps로 돈다.

## 1. 전체 그림 — 하나의 커맨드 버퍼

```
AVCaptureVideoDataOutput (CVPixelBuffer, 420v/BGRA, IOSurface backed)
        │  CVMetalTextureCache  (zero-copy)
        ▼
┌───────────────── 단일 MTL4CommandBuffer ─────────────────────────────┐
│                                                                       │
│  [C0] preprocess     420v→RGB, 518×392 리샘플, 정규화 → MTLTensor(f32)│
│         ↓ barrier                                                     │
│  [ML]  dispatchNetwork(intermediatesHeap:)      ← 15.4ms 실측         │
│         ↓ barrier                     depth tensor 518×392 (행패딩 528)│
│  [C1] depth stabilize  affine 정합 + 시간필터 + person matte 합성      │
│  [C2] upsample         joint bilateral (color guide) → half-res       │
│  [C3] geometry         언프로젝션 → view-space P, 5-tap 노멀 → G버퍼   │
│  [C4] AO               half-res GTAO                                  │
│  [C5] relight          레이마칭 그림자 + 확산 + GGX 스펙큘러           │
│  [C6] resolve          시간누적 + 업스케일 + 톤매핑                    │
│         ↓                                                             │
│  [R0] composite/present                                               │
└───────────────────────────────────────────────────────────────────────┘
        │
        ▼  FrameSink (Preview / Syphon / CMIO)
```

핵심은 **추론 출력이 GPU 메모리를 떠나지 않는다**는 것이다.
`MTLBuffer.makeTensor(descriptor:offset:)`로 만든 buffer-backed 텐서를 ML 인코더가 쓰고,
바로 다음 컴퓨트 인코더가 같은 `MTLBuffer`를 읽는다. CPU 왕복도, 포맷 변환도 없다.

### 레이트 분리 (중요)

| 스테이지 | 주기 | 이유 |
|---|---|---|
| 캡처 | 30/60 Hz | 소스에 종속 |
| **깊이 추론** | **30 Hz** | 15.4ms. 60Hz면 GPU 예산을 다 먹는다 |
| person matte (Vision) | 15 Hz | 실루엣은 천천히 변한다 |
| 리라이팅/렌더 | **60 Hz** | 손 움직임에 대한 반응성이 곧 체감 품질 |
| 배경 깊이 앵커(무거운 모델) | 0.2 Hz | 웹캠은 배경이 정적이다 — 이 도메인의 특권 |

깊이 30Hz + 렌더 60Hz면 렌더 프레임의 절반은 **직전 깊이맵을 재사용**한다.
사람은 초당 몇 cm 움직이므로 33ms 묵은 깊이는 눈에 안 띈다. 반면 조명이 손을 33ms 늦게 따라오면 즉시 티가 난다.

---

## 2. [C0] 전처리

- 카메라 네이티브는 `420v`(biplanar YCbCr). BGRA 변환보다 대역폭이 절반이니 **YCbCr 그대로 받아서 셰이더에서 변환**한다. `CVMetalTextureCache`로 plane 0(Y), plane 1(CbCr) 두 텍스처를 얻는다.
- 모델 입력은 518×392. 원본 종횡비(16:9 또는 1:1)와 다르다.
  DAv2는 **stretch(비율 무시 리사이즈)로 학습**되었으므로 letterbox보다 stretch가 맞다.
- 정규화: ImageNet mean/std. Core ML 모델은 이미 내장하고 있지만, **mtlpackage 경로는 그래프 입력이 f32 텐서**이므로 우리가 직접 넣어야 한다.
- 출력 텐서 쓰기 시 **행 패딩(528 elem for 518)** 반드시 반영:
  ```metal
  device float *dst;  // 텐서 백킹 버퍼
  const uint rowStride = 528;                 // (518*4 → 2112B) / 4
  dst[c * 392 * rowStride + y * rowStride + x] = v;
  ```

---

## 3. [ML] 추론

```swift
let lib = try device.makeLibrary(URL: mtlpackageURL)      // functionNames == ["main"]
let fd = MTL4LibraryFunctionDescriptor(); fd.name = "main"; fd.library = lib
let pd = MTL4MachineLearningPipelineDescriptor()
pd.machineLearningFunctionDescriptor = fd
pd.setInputDimensions(extents([518, 392, 3, 1]), bufferIndex: 0)   // innermost가 첫 원소
let pso = try compiler.makeMachineLearningPipelineState(descriptor: pd)

let enc = cb.makeMachineLearningCommandEncoder()!
enc.setPipelineState(pso)
enc.setArgumentTable(argTable)          // 텐서는 gpuResourceID로 바인딩
enc.dispatchNetwork(intermediatesHeap: heap)   // heap = pso.intermediatesHeapSize
enc.endEncoding()
```

`DepthProvider` 프로토콜로 추상화해 Core ML(ANE) 경로와 교체 가능하게 둔다.
ANE 경로는 GPU를 안 쓰므로 **GPU가 렌더로 포화될 때의 탈출구**다(20.8ms지만 GPU 예산 0).

---

## 4. [C3] 언프로젝션 — 초점거리가 없다는 문제

DAv2 출력은 **affine-invariant inverse depth** `d ∈ [0,1]`이다. 미터가 아니고, 프레임마다 스케일이 다르다.

```
Z(u,v) = 1 / (a·d(u,v) + b)                     # a,b는 프레임별 정합으로 구함 (§5)
P(u,v) = Z · ( (u-cx)/fx , (v-cy)/fy , 1 )      # fx가 필요하다
```

**macOS는 fx를 안 준다** (`videoFieldOfView`, `cameraIntrinsicMatrixDelivery` 모두 iOS 전용 — 실측 확인).

대응 3단(순서대로 시도):

1. **얼굴 기반 캘리브레이션** — `DetectFaceLandmarksRequest`로 두 눈동자 픽셀거리 `p`를 얻는다.
   성인 평균 동공간거리(IPD)는 63mm. 사용자가 정면일 때
   ```
   fx ≈ p · Z_face / 0.063
   ```
   `Z_face`는 미지수지만, "웹캠 앞 사람"이라는 사전지식(0.4~0.9m, 중앙값 0.6m)을 넣으면
   `fx`가 한 번에 결정된다. 3초 정도 중앙값을 모아 고정한다.
2. **hFOV 고정 가정** — 맥 내장/일반 웹캠은 대체로 hFOV 55~65°. `fx = (W/2)/tan(hFOV/2)`로 60° 가정.
3. **사용자 슬라이더** — "조명 원근" 한 개. 물리적으로는 fx지만 사용자에겐 그냥 느낌 조절기다.

> 실용적 진실: 조명 배치는 **상대적 일관성**만 있으면 그럴듯해 보인다.
> fx가 20% 틀려도 사람은 모른다. 틀리면 티나는 건 **프레임 간 변동**이다. 그래서 fx는 한 번 정하고 **절대 안 바꾼다.**

### 노멀 재구성

단순 `ddx/ddy` 외적은 실루엣 경계에서 깨진다(얼굴 윤곽 전체에 거짓 하이라이트가 생김).
**5-tap accurate reconstruction**을 쓴다: 좌/우, 상/하 각 2탭씩 더 떠서 깊이 불연속이 없는 쪽 이웃을 고른다.

```metal
float3 reconstructNormal(float2 uv) {
    float3 c  = viewPos(uv);
    float3 l1 = viewPos(uv + float2(-dx,0)), l2 = viewPos(uv + float2(-2*dx,0));
    float3 r1 = viewPos(uv + float2( dx,0)), r2 = viewPos(uv + float2( 2*dx,0));
    float3 d1 = viewPos(uv + float2(0,-dy)), d2 = viewPos(uv + float2(0,-2*dy));
    float3 u1 = viewPos(uv + float2(0, dy)), u2 = viewPos(uv + float2(0, 2*dy));
    // 2차 미분이 작은 쪽(= 불연속이 없는 쪽)을 채택
    float3 h = abs(l1.z*2 - l2.z - c.z) < abs(r1.z*2 - r2.z - c.z) ? (c - l1) : (r1 - c);
    float3 v = abs(d1.z*2 - d2.z - c.z) < abs(u1.z*2 - u2.z - c.z) ? (c - d1) : (u1 - c);
    return normalize(cross(v, h));
}
```

**디테일 주입 (학습 없이 품질을 크게 올리는 트릭)**
ViT-S 깊이맵은 코·입술·귀의 미세 기복을 뭉갠다 → 조명이 평평해 보인다.
피부는 대체로 램버시안이므로 **원본 루마의 고주파 ≈ 지오메트리 고주파**다.

```metal
float hi = luma(src) - blur5x5(luma(src));      // high-pass
N.xy += hi * detailStrength;                     // 0.3~0.8
N = normalize(N);
```

셰이더 3줄이고, 파인튜닝보다 먼저 해야 할 일이다.

---

## 5. [C1] 깊이 안정화 — **품질의 8할이 여기 있다**

### 문제 1. affine 스케일 드리프트
상대깊이라 프레임마다 `a, b`가 흔들린다. 3D에 고정한 조명 기준으로 보면 **씬 전체가 앞뒤로 펌핑**한다.

해법: **배경을 앵커로 쓴다.** person matte 바깥 픽셀만으로 직전 프레임의 EMA 기준에 robust affine fit(중앙값/MAD).
사람이 움직여도 배경은 안 움직이므로 스케일이 고정된다.

```
a, b = argmin Σ_{bg} | (a·d_t + b) − d_ref |     (median 기반, RANSAC 불필요)
d_ref ← lerp(d_ref, a·d_t + b, 0.02)             // 아주 느린 갱신
```

### 문제 2. 플리커
프레임 독립 추론이라 픽셀 단위로 떨린다. Video Depth Anything(CVPR'25)이 학습으로 푸는 문제지만 무겁다.
실시간에선 **edge-stopping 시간필터**로 대응:

```metal
float wColor = exp(-dot(dc,dc) / sigmaC);       // 색이 많이 변한 픽셀은 히스토리 기각
float wDepth = exp(-abs(dPrev - dCur) / sigmaD);
d = mix(dCur, dPrev, 0.85 * wColor * wDepth);
```

색 가중치를 빼면 사람이 움직일 때 깊이가 끌린다(고스팅). 반드시 넣는다.

### 문제 3. 업샘플 — 실루엣이 새면 그림자가 얼굴 밖으로 샌다
518×392 → 1080p를 bilinear로 올리면 경계가 뭉개진다.
**joint bilateral upsample**(원본 컬러를 guide로) + **person matte로 하드 컷**.
matte는 `GeneratePersonSegmentationRequest`(.balanced, 15Hz)로 얻는다. M1에서 60fps 나오는 수준이라 여유롭다.

---

## 6. [C5] 리라이팅 — 원본 조명을 어떻게 다룰 것인가

### 왜 "완전 재조명"을 하면 안 되는가
원본 프레임에는 이미 조명이 구워져 있다. 진짜 재조명은 albedo/normal/roughness/specular로 분해(intrinsic decomposition)해야 하는데, 그게 SwitchLight급 파이프라인이고 실시간이 아니다.

### 우리 전략: delta lighting (가산 조명)
원본을 **환경광으로 보존**하고, 가상 광원의 기여만 더한다. 물리적으로도 옳다 — 실제로 스탠드 조명을 켜는 것과 같은 연산이다.

```metal
// 1) pseudo-albedo: 저주파 밝기를 나눠서 텍스처만 남긴다 (Retinex 근사)
float3 base  = src / max(pow(blurWide(luma(src)), gamma), 1e-3);

// 2) 확산
float  NdotL = saturate(dot(N, L));
float  atten = 1.0 / (1.0 + k1*dist + k2*dist*dist);
float3 diffuse = base * NdotL * atten * lightColor * intensity;

// 3) 스펙큘러 — "고급스러움"의 8할이 여기서 나온다
float3 H = normalize(L + V);
float  a = roughness * roughness;               // 피부 0.4~0.6
float  D = a*a / (PI * pow(pow(dot(N,H),2)*(a*a-1)+1, 2));
float  F = 0.028 + (1-0.028) * pow(1 - dot(V,H), 5);   // 피부 F0 = 0.028
float3 spec = D * F * G_smith * skinMask;

// 4) 합성
float3 outc = src + (diffuse + spec) * shadow;
outc = tonemapACES(outc);                       // 클리핑 방지 필수
```

`skinMask`는 얼굴 랜드마크 영역 + 색상 기반 피부 검출로 만든다. 옷이나 배경에 피부 스펙큘러가 뜨면 가짜티가 난다.

### 반사광(간접광)
진짜 GI는 과하다. 두 단계 근사:
- **필 라이트**: 광원이 비춘 밝은 픽셀들을 1/8 해상도로 다운샘플 → 블러 → 반대 방향에서 약하게 되먹임. SSGI의 축소판이고 2~3ms면 된다
- **AO**: half-res GTAO. 목 아래·턱밑·코 옆에 접촉 그늘이 생겨 입체감이 급상승한다. 광원 유무와 무관하게 항상 켜두는 게 이득

---

## 7. [C5] 레이마칭 그림자 — POM과 같은 알고리즘

핵심 통찰: **화면공간 깊이버퍼를 높이장(height field)으로 보면, POM의 셀프섀도우와 스크린스페이스 섀도우는 같은 알고리즘이다.**

```metal
// 픽셀의 뷰공간 위치 P에서 광원 L까지 광선을 진행시키며,
// 매 스텝 화면에 재투영해서 그 위치의 씬 깊이와 비교한다.
float traceShadow(float3 P, float3 L, float thickness) {
    float3 dir = normalize(L - P);
    float  len = min(distance(L, P), maxTraceDist);
    float  step = len / STEPS;                    // STEPS = 16~32
    float3 p = P + dir * step * blueNoise(gid);   // 지터로 밴딩 제거
    for (int i = 0; i < STEPS; ++i) {
        float2 uv = project(p);
        if (any(uv < 0) || any(uv > 1)) break;    // 화면 밖 → 조기 종료
        float zScene = sceneZ(uv);
        float delta  = p.z - zScene;              // 광선이 씬보다 뒤에 있으면 양수
        if (delta > bias && delta < thickness)    // ★ thickness가 전부다
            return 0.0;                           // 가려짐
        p += dir * step;
    }
    return 1.0;
}
```

### thickness — 이 파이프라인에서 가장 위험한 파라미터

모노큘러 깊이는 **2.5D**다. 물체의 "뒤쪽"을 모른다.
thickness를 무한대로 두면 배경 픽셀 전부가 사람 뒤에 있다고 판정되어 **화면 전체가 검게 죽는다.**
너무 작으면 그림자가 아예 안 생긴다.

두께 프라이어를 넣는다:
```
thickness(uv) = personMatte(uv) > 0.5
              ? 0.25 * faceWidthInMeters      // 사람 몸통 두께 ≈ 얼굴폭의 25%
              : 0.05                           // 배경은 얇게
```
이것이 "카메라와 가까운 오브젝트가 빛을 가린다"를 성립시키는 **유일한 장치**다.

### 그 외 실무 대응
- **화면 밖으로 나간 광선**: 딱 자르면 경계선이 보인다 → 마지막 20%에서 shadow를 1.0으로 페이드
- **노이즈**: 블루노이즈 지터 + 시간 누적(직전 프레임 shadow를 모션 없이 EMA) + depth-aware 블러
- **광원이 카메라보다 뒤(z < 0)**: 광선이 시작부터 화면 뒤로 간다 → 마칭이 무의미.
  이 경우 `shadow = 1.0`으로 두고 `NdotL`만으로 **림라이트**를 만든다. (뒤에서 비추는 조명은 오히려 예쁘다)
- **성능**: half-res에서 32스텝 → 1080p 기준 실효 16.6M 샘플. M5 GPU에서 2~3ms 수준

---

## 8. 손 인터랙션 — 핀치로 3D 조명 잡기

### 핀치 검출
```swift
var req = DetectHumanHandPoseRequest()
req.maximumHandCount = 1          // 지연에 직접 영향. 필요한 최솟값으로.
```
`thumbTip`–`indexTip` 정규화 거리 `d`에 **히스테리시스**를 건다.

| 상태 | 전이 조건 |
|---|---|
| open → pinched | `d < 0.045` && confidence > 0.6 && 3프레임 연속 |
| pinched → open | `d > 0.070` |

임계값 하나로 하면 경계에서 채터링이 난다. 반드시 두 개로 분리한다.

### ★ z(깊이)를 어디서 얻는가 — 별도 센서가 필요 없다

**손이 프레임 안에 있으므로 깊이맵이 이미 손의 깊이를 갖고 있다.**
핀치 지점(엄지·검지 중점)에서 같은 깊이맵을 샘플하면 끝이다.

단, 손끝은 얇아서 깊이가 배경으로 샌다. 그래서 **중점 주변 5×5 중 가장 가까운 분위수(상위 20%)** 를 쓴다:
```
z_pinch = quantile_0.8( inverseDepth(5×5 neighborhood) )   // inverse depth라 클수록 가까움
```

**보조 신호로 융합**: 손 크기(`wrist`↔`middleMCP` 픽셀거리)는 `1/Z`에 비례한다.
깊이 샘플과 상보 필터로 섞으면, 손이 프레임 경계에 걸리거나 깊이가 튈 때 버텨준다.
```
z = 0.7 * z_depthmap + 0.3 * z_handsize
```

### 제스처 매핑

| 제스처 | 매핑 |
|---|---|
| 한 손 핀치 + 드래그 | 조명 3D 이동 (x,y = 화면, **z = 손 깊이**) |
| 두 손 핀치 간격 | 광원 반경(소프트섀도우 부드러움) 또는 세기 |
| 핀치 후 손목 회전 | 색온도 |
| 핀치 해제 | 그 자리에 고정 |
| 주먹 2초 | 리셋 |

### ⚠️ 좌표계 함정
사용자는 **거울상 프리뷰**를 본다. 조명이 손을 따라오게 하려면 프리뷰 좌표계와 송출 좌표계를 **분리**해야 한다.
Vision 좌표는 좌하단 원점 정규화, Metal은 좌상단 — y 뒤집기를 한 곳에서만 하고 그 지점을 문서화한다.
(이 버그는 반드시 한 번 난다. 미리 정해두면 30분을 아낀다.)

### 공짜로 얻는 최고의 데모 순간
손이 화면 안에 있으면 **손 자체가 깊이맵에 있으므로, 손이 얼굴에 그림자를 드리운다.**
조명을 손으로 잡고 얼굴 옆으로 가져가면 손 그림자가 뺨을 가로지른다. 별도 구현이 필요 없다.
이 장면 하나가 "이거 진짜 3D로 계산하는구나"를 3초 만에 증명한다.

---

## 9. 성능 예산

60fps = 16.7ms, 30fps = 33.3ms.

| 스테이지 | 예산 | 근거 |
|---|---|---|
| 전처리 (C0) | 0.5 ms | 리샘플 + 정규화 |
| **추론 (ML)** | **15.4 ms / 2프레임** | 실측. 30Hz로 돌리므로 프레임당 실효 7.7ms |
| 깊이 안정화 (C1) | 1.0 ms | half-res 필터 |
| 업샘플 (C2) | 1.0 ms | joint bilateral |
| 지오메트리 (C3) | 0.8 ms | 5-tap 노멀 |
| AO (C4) | 1.5 ms | half-res GTAO |
| 리라이팅 + 레이마칭 (C5) | 3.0 ms | half-res, 32스텝 |
| resolve (C6) | 1.0 ms | 시간누적 + 업스케일 |
| **합계** | **~16.5 ms** | 60fps에 아슬아슬하게 맞음 |

여유가 없으면 순서대로 깎는다: ① 레이마칭 32→16스텝 ② AO 끄기 ③ 추론 20Hz ④ 출력 30fps.
**출력 30fps는 사실상 무료다 — Zoom이 어차피 30fps로 인코딩한다.**

---

## 10. 모듈 경계

```swift
protocol DepthProvider {            // Metal4ML / CoreMLANE 교체 가능
    func encode(into cb: MTL4CommandBuffer, source: MTLTexture) -> MTLTensor
}
protocol HandTracker {              // Vision / (나중에) 커스텀
    var pinch: PinchState { get }
}
protocol FrameSink {                // Preview / Syphon / CMIO
    func submit(_ texture: MTLTexture, pts: CMTime)
}
struct LightRig {                   // 씬에 놓인 광원들 (다중 광원 확장 여지)
    var lights: [PointLight]        // pos(view space), color, intensity, radius
}
```

각 경계는 "이게 실패해도 나머지가 산다"를 기준으로 그었다.
- `DepthProvider`가 느리면 → ANE로 교체
- `FrameSink`가 막히면 → 프리뷰만으로 데모
- `HandTracker`가 불안하면 → 마우스 드래그 폴백 (데모 안전장치로 **반드시 만들어 둘 것**)
