// bench_depth.swift — Core ML depth 모델의 compute unit별 실측
// 실행: xcrun swiftc -O -o /tmp/bench relight/tools/bench_depth.swift && /tmp/bench <path.mlmodelc>
import Foundation
import CoreML
import CoreVideo
import QuartzCore

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "relight/models/DepthAnythingV2SmallF16.mlmodelc"
let url = URL(fileURLWithPath: path)

func describe(_ m: MLModel) {
    let d = m.modelDescription
    print("— inputs —")
    for (k, v) in d.inputDescriptionsByName {
        var s = "  \(k): \(v.type.rawValue)"
        if let img = v.imageConstraint { s += "  image \(img.pixelsWide)x\(img.pixelsHigh) fmt=\(img.pixelFormatType)" }
        if let ma = v.multiArrayConstraint { s += "  multiArray \(ma.shape) dtype=\(ma.dataType.rawValue)" }
        print(s)
    }
    print("— outputs —")
    for (k, v) in d.outputDescriptionsByName {
        var s = "  \(k): \(v.type.rawValue)"
        if let img = v.imageConstraint { s += "  image \(img.pixelsWide)x\(img.pixelsHigh) fmt=\(img.pixelFormatType)" }
        if let ma = v.multiArrayConstraint { s += "  multiArray \(ma.shape) dtype=\(ma.dataType.rawValue)" }
        print(s)
    }
}

func makePixelBuffer(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb)
    return pb!
}

func bench(_ units: MLComputeUnits, _ label: String) {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = units
    guard let model = try? MLModel(contentsOf: url, configuration: cfg) else {
        print("\(label): LOAD FAILED"); return
    }
    let d = model.modelDescription
    guard let (name, desc) = d.inputDescriptionsByName.first else { return }
    var feats: [String: Any] = [:]
    if let ic = desc.imageConstraint {
        feats[name] = makePixelBuffer(ic.pixelsWide, ic.pixelsHigh, ic.pixelFormatType)
    } else if let mc = desc.multiArrayConstraint {
        feats[name] = try! MLMultiArray(shape: mc.shape, dataType: mc.dataType)
    }
    let input = try! MLDictionaryFeatureProvider(dictionary: feats)
    for _ in 0..<5 { _ = try? model.prediction(from: input) }   // warmup
    var times: [Double] = []
    for _ in 0..<40 {
        let t0 = CACurrentMediaTime()
        _ = try? model.prediction(from: input)
        times.append((CACurrentMediaTime() - t0) * 1000)
    }
    times.sort()
    let med = times[times.count/2], p10 = times[times.count/10], p90 = times[times.count*9/10]
    print(String(format: "%-22@ median %6.2f ms   p10 %6.2f   p90 %6.2f   (=%.1f fps)",
                 label as NSString, med, p10, p90, 1000/med))
}

if let m = try? MLModel(contentsOf: url) { describe(m) }
print("\n— 실측 (M5) —")
bench(.all, "all (ANE 우선)")
bench(.cpuAndNeuralEngine, "cpu+ANE")
bench(.cpuAndGPU, "cpu+GPU")
bench(.cpuOnly, "cpu only")
