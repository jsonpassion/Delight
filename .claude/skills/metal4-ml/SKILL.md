---
name: metal4-ml
description: Metal 4 ML 인코더(MTL4MachineLearningCommandEncoder)로 신경망을 GPU 타임라인에서 실행할 때 사용. mlpackage를 mtlpackage로 변환하거나, MTLTensor를 만들거나, 추론 출력을 컴퓨트 셰이더로 넘기거나, "텐서 생성 실패"·"MPSGraph assert"·"피드백 핸들러가 안 불림" 같은 증상을 디버깅할 때 읽는다. 이 프로젝트에서 실측으로 확인한 제약들이 들어 있다.
---

# Metal 4 ML 인코더

macOS 26 / Apple Silicon에서 추론·라이팅·드로우를 **하나의 커맨드 버퍼**로 잇는 경로.
CPU 동기화가 없고, 추론 출력이 GPU 메모리를 떠나지 않는다.

M5 실측(518×392 Depth Anything V2-small, 40회 median): **15.42 ms** — Core ML/ANE의 20.78 ms보다 빠르다.

## 변환

```bash
xcrun metal-package-builder -ml Model.mlpackage -o Model.mtlpackage
```

입력은 **coremlpackage**여야 한다(mlmodelc 아님). 결과물 내부는 `library.mpsgraphpackage`이고,
함수 이름은 항상 `"main"`이다(`library.functionNames`로 확인 가능).

## 실측으로 확인한 제약 — 문서에 잘 안 나오는 것들

1. **device-alloc 텐서는 strides가 반드시 nil이어야 한다.**
   `MTLDevice.makeTensor(descriptor:)`에 strides를 주면 `Tensor Descriptor Validation` 에러.
   셰이더가 읽어야 하는 텐서는 `MTLBuffer.makeTensor(descriptor:offset:)`로 만든다.

2. **`MTLTensorUsageMachineLearning`이면 `strides[1]`이 64바이트 정렬이어야 한다.**
   f32 518열 = 2072B → 2112B(528 elem)로 패딩된다.
   `((width * elementBytes + 63) / 64) * 64 / elementBytes`
   **셰이더는 이 행 패딩을 반드시 계산에 넣어야 한다.** width로 인덱싱하면 이미지가 비스듬히 밀린다.

3. **변환된 그래프는 f32 입출력을 기대한다.**
   f16 텐서를 물리면 `mlir module expected element type f32 but received f16` assert로 죽는다.

4. **커밋 피드백 핸들러를 쓰려면 `MTL4CommandQueueDescriptor.feedbackQueue`를 지정해야 한다.**
   지정하지 않으면 콜백이 영영 오지 않고 세마포어에서 무한 대기한다.
   동기화만 필요하면 `MTLSharedEvent`가 더 단순하고 확실하다.

5. **Metal 4는 자동 레지던시가 없다.** 버퍼·힙을 `MTLResidencySet`에 넣고 큐에 붙인다.

6. `MTLTensorExtents`는 Swift에서 `init(__rank:values:)`로 만든다. **첫 원소가 innermost(W)** 다.

## 최소 실행 형태

```swift
let library = try device.makeLibrary(URL: mtlpackageURL)
let fn = MTL4LibraryFunctionDescriptor(); fn.name = "main"; fn.library = library

let pd = MTL4MachineLearningPipelineDescriptor()
pd.machineLearningFunctionDescriptor = fn
pd.setInputDimensions(extents([W, H, 3, 1]), bufferIndex: 0)
let pso = try compiler.makeMachineLearningPipelineState(descriptor: pd)

// intermediatesHeapSize만큼의 placement 힙
let encoder = commandBuffer.makeMachineLearningCommandEncoder()!
encoder.setPipelineState(pso)
encoder.setArgumentTable(argumentTable)     // 텐서는 gpuResourceID로 바인딩
encoder.dispatchNetwork(intermediatesHeap: heap)
encoder.endEncoding()
```

## 검증 습관

벤치 수치만 보고 "돌아간다"고 판단하지 말 것. **결정적 입력을 넣고 출력 통계를 확인한다.**
min/max가 같으면(상수) 네트워크가 실제로 실행되지 않은 것이다.
`Tools/bench_mtl4ml.swift`가 이 검증을 포함하고 있다.

## 참고

- 파이프라인 전체: `docs/01-architecture.md`
- 실측 근거: `docs/00-feasibility.md` §2
