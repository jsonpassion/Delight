# Metal 로직 강화 리서치

> 조사 2026-08-21 · 대상: 현재 파이프라인(높이장 + 텍스처 공간 POM)
> 기준선: gpu 21~24 ms · 균일 16스텝 · 출력 1552×1552

## 0. 먼저, 어디에 비용이 있는가

추측 대신 워크로드 규모를 셌다. 최적화 대상을 고르는 근거다.

| | 픽셀 | 샘플/픽셀 | 텍스처 페치 |
|---|---:|---:|---:|
| **레이마칭 그림자** | 2,408,704 | 16 | **38,539,264** |
| AO | 203,056 | 16 | 3,248,896 |

**레이마칭이 AO의 12배다.** 높이장 자체는 793 KB(rg16Float)로 작다.

이 두 숫자가 아래 판단을 거의 다 결정한다 — 손댈 곳은 레이마칭이고,
높이장이 작다는 사실은 메모리 최적화의 여지를 없앤다.

---

## 1. 시간 누적 (temporal accumulation) — **1순위**

### 왜 이것이 먼저인가

레이마칭 스텝을 줄이면 페치가 선형으로 준다.

| 스텝 | 페치 | 절감 |
|---:|---:|---:|
| 16 (현재) | 38.5 M | — |
| 8 | 19.3 M | 50% |
| 6 | 14.5 M | 62% |
| 4 | 9.6 M | 75% |

스텝을 줄이면 그림자에 노이즈가 생긴다. **그 노이즈를 시간으로 흡수하는 것**이
[실시간 레이트레이싱이 1 spp로 60 fps를 내는 방식](https://github.com/microsoft/DirectX-Graphics-Samples/blob/master/Samples/Desktop/D3D12Raytracing/src/D3D12RaytracingRealTimeDenoisedAmbientOcclusion/readme.md)이다.

### 이 프로젝트에 특히 유리한 이유

일반적인 시간 누적의 최대 난점은 **모션 벡터**다. 카메라가 움직이면
이전 프레임의 어느 픽셀이 지금 어디로 갔는지 계산해야 한다.

우리는 그 문제가 거의 없다.

- **카메라가 고정**이다. 웹캠은 책상에 붙어 있다
- 움직이는 것은 사람과 손뿐이고, 그마저 프레임 간 이동이 작다
- 배경은 사실상 정지 — 시간 누적이 가장 잘 듣는 조건

즉 **모션 벡터 없이 같은 좌표를 재사용**해도 대부분 맞는다.
이건 일반 엔진이 부러워할 조건이다.

### 이미 절반은 갖고 있다

`Stabilize.metal`의 edge-stopping 시간필터가 정확히 같은 구조다.

```metal
float colorWeight = exp(-dot(colorDelta, colorDelta) / u.colorSigma);
float depthWeight = exp(-depthDelta / u.depthSigma);
output = mix(current, previous, u.temporalBlend * colorWeight * depthWeight);
```

깊이에 쓰던 것을 그림자에 그대로 쓰면 된다. 핑퐁 버퍼 패턴도 이미 있다.

### 구현 계획

1. 그림자 결과를 별도 텍스처(r8Unorm, 출력 해상도)에 쓴다
2. 프레임마다 지터를 바꿔 서로 다른 위치를 샘플한다(이미 `dither(gid)`가 있다)
3. 이전 프레임 그림자와 섞되, **색·높이 변화가 크면 히스토리를 기각**한다
4. 스텝을 16 → 6으로 낮춘다

### 위험

- **고스팅**: 손이 빠르게 움직이면 그림자가 끌린다. edge-stopping 가중치가 방어선이고,
  깊이 안정화에서 이미 검증된 방식이다
- [variance clamping](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11232544)
  (이웃의 평균±표준편차로 히스토리를 제한)을 추가하면 더 안전하다
- 텍스처 2개 추가(핑퐁) — 출력 해상도 r8이면 2.4 MB × 2

**기대**: 페치 62% 감소. 품질은 시간 누적으로 유지하거나 오히려 개선.

---

## 2. Pre-integrated skin shading — **2순위 (품질)**

### 지금 무엇이 부족한가

현재 피부 산란은 wrap diffuse 한 줄이다.

```metal
float wrapped = saturate((dot(normal, L) + u.wrapDiffuse) / (1.0 + u.wrapDiffuse));
```

명암 경계를 부드럽게 만들 뿐, **빛이 피부 속으로 들어가 붉게 번지는 것**은 없다.
귀·콧망울처럼 얇은 곳에서 실제 피부가 보이는 특징이 빠져 있다.

### Penner의 방식

[Pre-Integrated Skin Shading](https://developer.nvidia.com/gpugems/gpugems3/part-iii-rendering/chapter-14-advanced-techniques-realistic-real-time-skin)은
산란 결과를 **곡률과 N·L의 2D 룩업 테이블**로 미리 구워둔다.

- 추가 렌더 패스가 **없다**. 픽셀 셰이더 한 번으로 끝난다
- [텍스처 공간 확산이나 separable SSS(최대 12회 1D 컨볼루션)보다 훨씬 싸다](https://therealmjp.github.io/posts/sss-intro/)
- 곡률이 클수록(코끝, 귀) 산란이 강하게 보이는 것이 자연스럽게 나온다

### 우리 구조에 맞는 점

곡률을 따로 구할 필요가 없다. **높이장의 2차 미분이 곧 곡률**이다.

```metal
// 이미 이웃 높이를 뜨고 있다 — 한 번 더 미분하면 곡률이다
float curvature = abs(hL + hR - 2.0 * height) + abs(hD + hU - 2.0 * height);
```

`build_height_field`가 이미 `hL/hR/hD/hU`를 샘플하므로 **추가 페치가 0**이다.
곡률을 노멀 텍스처의 빈 채널(w)에 실어 보내면 된다.

### 위험

- LUT를 만들어야 한다(작은 128×128 텍스처, 앱 시작 시 1회 계산)
- 깊이맵이 저해상도라 곡률이 뭉개진다 — 얼굴 전체 규모의 산란은 되지만
  콧망울 같은 미세 구조는 한계가 있다. 이건 4번(증류)이 풀 문제다

**기대**: 피부가 "빛나는 표면"에서 "빛이 스며드는 살"로 바뀐다. 비용은 LUT 페치 1회.

---

## 3. Max-mipmap 스킵 — **3순위 (조건부)**

### 계층 탐색과 무엇이 다른가

[앞서 이진 탐색 방식 계층화를 시도했고 측정이 기각했다](../web/pipeline.html)
(균일 29.8 ms vs 계층 31.0 ms). 워프 발산과 의존적 페치가 원인이었다.

[Maximum Mipmap](https://arxiv.org/pdf/2005.06671)은 성격이 다르다.
하위 레벨의 **최대 높이**를 저장해두고, 광선이 그 최대값보다 높으면
그 블록 전체를 **한 번에 건너뛴다**.

- 이진 탐색처럼 스텝을 쪼개는 게 아니라 **빈 공간을 통째로 스킵**한다
- [Quadtree Displacement Mapping](https://www.gamedevs.org/uploads/quadtree-displacement-mapping-with-height-blending.pdf)과
  [cone step mapping](https://en.wikipedia.org/wiki/Parallax_occlusion_mapping)도 같은 계열

### 그런데 우리에게 이득이 작을 수 있다

- 우리 스텝은 이미 **16**으로 적다. 스킵으로 줄일 여지가 크지 않다
- 밉 생성 비용이 **매 프레임** 든다(높이장이 매 프레임 바뀐다)
- 밉 레벨을 오르내리는 것 자체가 분기다 — 계층 탐색이 실패한 이유와 겹친다

**판단**: 1번(시간 누적)으로 스텝을 6까지 낮춘 뒤에도 부족하면 그때 본다.
지금 하면 계층화와 같은 결과가 나올 가능성이 높다.

---

## 4. threadgroup 메모리 타일링 — **보류**

레이마칭은 이웃 픽셀이 거의 같은 높이장 영역을 읽는다.
타일을 threadgroup 메모리에 올리면 대역폭이 준다 — 교과서적인 최적화다.

**그런데 M5에서는 이득이 없을 수 있다.**

[Apple Family 9 이상의 GPU는 dynamic shader core memory와 flexible on-chip memory를 갖고 있어,
워킹셋이 캐시에 맞으면 threadgroup 메모리로 복사하는 지연을 피하고
device 버퍼를 직접 쓰는 편이 낫다](https://developer.apple.com/videos/play/tech-talks/111373/).

우리 높이장은 **793 KB**다. M5의 캐시 계층에 충분히 들어간다.
즉 이미 캐시가 그 역할을 하고 있을 가능성이 높고,
threadgroup 복사는 순수한 추가 비용이 된다.

**판단**: 측정 없이 손대지 않는다. 계층화에서 배운 것이 정확히 이것이다 —
교과서 최적화가 이 하드웨어에서도 옳다는 보장은 없다.

---

## 5. 우선순위와 근거

| 순위 | 항목 | 기대 | 위험 | 근거 |
|---|---|---|---|---|
| 1 | **시간 누적** | 페치 62%↓ | 고스팅 | 카메라 고정 = 모션 벡터 문제 없음. 구조를 이미 갖고 있음 |
| 2 | **pre-integrated skin** | 피부 품질 | LUT 관리 | 곡률이 공짜(높이장 2차 미분), 추가 패스 0 |
| 3 | max-mipmap | 조건부 | 계층화 재연 | 1번 이후에도 부족하면 |
| — | threadgroup 타일 | 불확실 | 역효과 | 793 KB는 캐시에 들어간다 |

## 6. 측정 원칙 (이번 리서치에서 재확인)

계층화 실패와 threadgroup 조사가 같은 것을 말한다.

- **교과서 최적화가 이 하드웨어에서 옳다는 보장은 없다.** 반드시 A/B로 잰다
- **같은 세션에서 교차 측정**한다. 발열로 절대값이 밀린다
- **검증 레이어를 켜고** 잰다. 잘못된 바인딩이 조용히 지나가면 측정도 무효다
  (`MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`)
