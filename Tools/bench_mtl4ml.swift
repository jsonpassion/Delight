// bench_mtl4ml.swift — Metal 4 ML 인코더(GPU 타임라인) 경로 실측
// 실행: xcrun swiftc -O -o /tmp/bench4 relight/tools/bench_mtl4ml.swift && /tmp/bench4 <path.mtlpackage>
import Foundation
import Metal
import QuartzCore

let pkg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "relight/models/DepthAnythingV2Small.mtlpackage"
let dev = MTLCreateSystemDefaultDevice()!
func ext(_ v: [Int]) -> MTLTensorExtents { v.withUnsafeBufferPointer { MTLTensorExtents(__rank: v.count, values: $0.baseAddress)! } }

setvbuf(stdout, nil, _IONBF, 0)
print("device:", dev.name, "| Metal4:", dev.supportsFamily(MTLGPUFamily(rawValue: 5002)!))

let lib = try dev.makeLibrary(URL: URL(fileURLWithPath: pkg))
print("library functions:", lib.functionNames)

let fnName = lib.functionNames.first ?? "main"
let fd = MTL4LibraryFunctionDescriptor()
fd.name = fnName
fd.library = lib

let compiler = try dev.makeCompiler(descriptor: MTL4CompilerDescriptor())

func makePSO(_ dims: [Int]?) -> (any MTL4MachineLearningPipelineState)? {
    let pd = MTL4MachineLearningPipelineDescriptor()
    pd.label = "depth"
    pd.machineLearningFunctionDescriptor = fd
    if let d = dims { pd.setInputDimensions(ext(d), bufferIndex: 0) }
    return try? compiler.makeMachineLearningPipelineState(descriptor: pd)
}

var pso: (any MTL4MachineLearningPipelineState)?
var chosen: [Int] = []
for cand in [[518, 392, 3, 1], [392, 518, 3, 1], [3, 518, 392, 1], [518, 392, 1, 1]] {
    if let s = makePSO(cand) { pso = s; chosen = cand; print("input dims 채택: \(cand)"); break }
    print("  실패: \(cand)")
}
if pso == nil, let s = makePSO(nil) { pso = s; chosen = [518, 392, 3, 1]; print("input dims 미지정으로 컴파일 성공") }
guard let pso else { print("pipeline 컴파일 실패"); exit(1) }

print("intermediates heap:", pso.intermediatesHeapSize, "B")
for b in pso.reflection?.bindings ?? [] { print("  binding[\(b.index)] \(b.name) type=\(b.type.rawValue)") }

let heapDesc = MTLHeapDescriptor()
heapDesc.size = max(pso.intermediatesHeapSize, 4096)
heapDesc.storageMode = .private
heapDesc.type = .placement
let heap = dev.makeHeap(descriptor: heapDesc)!

func makeTensor(_ dims: [Int]) -> (MTLBuffer, MTLTensor) {
    let d = MTLTensorDescriptor()
    d.dataType = .float32          // 변환된 그래프는 f32 입출력을 기대한다(실측 확인)
    d.usage = [.machineLearning, .compute]
    d.storageMode = .shared      // 검증을 위해 CPU 읽기 가능하게(운영에서는 .private)
    d.dimensions = ext(dims)
    // 검증된 제약: MachineLearning usage일 때 strides[1]은 64바이트 정렬 필요.
    // f32(4B) 기준 → 행 stride를 16의 배수로 패딩한다.
    let elemBytes = 4
    let rowStride = ((dims[0] * elemBytes + 63) / 64) * 64 / elemBytes
    var strides = [1, rowStride]
    for i in 2..<dims.count { strides.append(strides[i-1] * dims[i-1]) }
    d.strides = ext(strides)
    let sa = dev.tensorSizeAndAlign(descriptor: d)
    let buf = dev.makeBuffer(length: sa.size, options: .storageModeShared)!
    return (buf, try! buf.makeTensor(descriptor: d, offset: 0))
}
let (inBuf, inTensor) = makeTensor(chosen)
let (outBuf, outTensor) = makeTensor([chosen[0], chosen[1], 1, 1])

let atDesc = MTL4ArgumentTableDescriptor()
atDesc.maxBufferBindCount = 8
let argTable = try dev.makeArgumentTable(descriptor: atDesc)
argTable.setResource(inTensor.gpuResourceID, bufferIndex: 0)
argTable.setResource(outTensor.gpuResourceID, bufferIndex: 1)

let rs = try dev.makeResidencySet(descriptor: MTLResidencySetDescriptor())
rs.addAllocation(inBuf); rs.addAllocation(outBuf); rs.addAllocation(heap)
rs.commit(); rs.requestResidency()

// feedback handler가 불리려면 queue에 feedbackQueue(dispatch queue)를 지정해야 한다(실측 확인).
let qDesc = MTL4CommandQueueDescriptor()
qDesc.feedbackQueue = DispatchQueue(label: "mtl4.feedback")
let queue = try dev.makeMTL4CommandQueue(descriptor: qDesc)
queue.addResidencySet(rs)
let alloc = dev.makeCommandAllocator()!
let cb = dev.makeCommandBuffer()!

let event = dev.makeSharedEvent()!
var signalValue: UInt64 = 0

func runOnce() {
    alloc.reset()
    cb.beginCommandBuffer(allocator: alloc)
    let enc = cb.makeMachineLearningCommandEncoder()!
    enc.setPipelineState(pso)
    enc.setArgumentTable(argTable)
    enc.dispatchNetwork(intermediatesHeap: heap)
    enc.endEncoding()
    cb.endCommandBuffer()
    queue.commit([cb])
    signalValue += 1
    queue.signalEvent(event, value: signalValue)
    if !event.wait(untilSignaledValue: signalValue, timeoutMS: 5000) {
        print("TIMEOUT waiting on shared event"); exit(2)
    }
}

for _ in 0..<5 { runOnce() }
var times: [Double] = []
for _ in 0..<40 {
    let t0 = CACurrentMediaTime()
    runOnce()
    times.append((CACurrentMediaTime() - t0) * 1000)
}
times.sort()
print(String(format: "\nMetal4 ML encoder: wall median %.2f ms (p10 %.2f / p90 %.2f) = %.1f fps",
             times[times.count/2], times[times.count/10], times[times.count*9/10], 1000/times[times.count/2]))

// --- 네트워크가 실제로 도는지 검증: 알려진 입력 → 출력 통계 ---
let inCount = inBuf.length / 4
let inPtr = inBuf.contents().bindMemory(to: Float.self, capacity: inCount)
for i in 0..<inCount { inPtr[i] = Float(i % 97) / 97.0 }   // 결정적 패턴
runOnce()
let outCount = outBuf.length / 4
let outPtr = outBuf.contents().bindMemory(to: Float.self, capacity: outCount)
var mn = Float.infinity, mx = -Float.infinity, sum: Double = 0, nan = 0
for i in 0..<outCount {
    let v = outPtr[i]
    if v.isNaN { nan += 1; continue }
    mn = min(mn, v); mx = max(mx, v); sum += Double(v)
}
print(String(format: "출력 검증: min %.4f  max %.4f  mean %.4f  NaN %d / %d",
             mn, mx, sum / Double(outCount - nan), nan, outCount))
print(mx > mn ? "→ 네트워크가 실제로 실행됨(출력에 변화 있음)" : "→ 의심: 출력이 상수")
