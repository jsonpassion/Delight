//
//  PersonMatte.swift
//  Vision 인물 세그멘테이션 → Metal 텍스처.
//
//  깊이 기반 근사 마스크는 실루엣이 뭉개져 그림자가 얼굴 밖으로 샌다.
//  정확한 매트가 있어야 레이마칭 두께 프라이어와 스펙큘러 마스크가 제 역할을 한다.
//  (docs/01-architecture.md §5 문제 3)
//
//  신형 Swift API(PixelBufferObservation)는 CVPixelBuffer를 직접 주지 않고 cgImage만 준다.
//  매 프레임 CGImage 변환은 비싸므로, CVPixelBuffer를 그대로 주는 legacy 요청을 쓴다.
//

import Vision
import CoreVideo
import Metal
import Foundation
import QuartzCore

nonisolated final class PersonMatte: @unchecked Sendable {

    /// 실루엣은 천천히 변한다. 매 프레임 돌릴 필요가 없다.
    static let targetHz: Double = 15

    private let request: VNGeneratePersonSegmentationRequest
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    /// 링으로 붙잡는다. GPU가 이전 프레임의 매트를 아직 읽고 있을 수 있으므로
    /// 한 개만 들고 있으면 교체 순간 IOSurface가 재활용되어 GPU가 밟는다.
    private var ring: [(texture: MTLTexture, retained: CVMetalTexture)] = []
    private var lastRun: CFTimeInterval = 0

    init?(device: MTLDevice, quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.textureCache = cache

        request = VNGeneratePersonSegmentationRequest()
        // .accurate은 실시간에 무겁고 .fast는 경계가 거칠다. 라이브에는 .balanced가 맞다.
        request.qualityLevel = quality
        // .r8Unorm 텍스처로 받으려면 단일 채널 8비트여야 한다.
        // 프로퍼티 이름은 outputPixelFormat이다(Type 접미사 없음).
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// 첫 모델 로드를 스트림 밖에서 미리 끝낸다. 레이트 제한을 우회한다.
    func warmUp(with pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        _ = try? handler.perform([request])
    }

    /// 한 프레임을 처리한다. 목표 주기(15Hz)는 여기서 스스로 지킨다 —
    /// 호출부가 메인 액터에서 시각을 재면 프레임마다 Task가 하나씩 더 생긴다.
    func process(pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        let due = now - lastRun >= 1.0 / Self.targetHz
        if due { lastRun = now }
        lock.unlock()
        guard due else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logOnce("세그멘테이션 perform 실패: \(error)")
            return
        }
        guard let observation = request.results?.first else {
            logOnce("세그멘테이션 결과 없음")
            return
        }
        guard let cache = textureCache else { return }

        let mask = observation.pixelBuffer
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, mask, nil, .r8Unorm, width, height, 0, &cvTexture)
        guard result == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            let format = CVPixelBufferGetPixelFormatType(mask)
            logOnce("매트 텍스처 생성 실패 code=\(result) \(width)x\(height) fmt=\(format)")
            return
        }

        // CVMetalTexture를 함께 잡고 있어야 texture가 유효하다.
        lock.lock()
        ring.append((texture, cvTexture))
        if ring.count > 3 { ring.removeFirst() }
        lock.unlock()
    }

    private var loggedMessages = Set<String>()
    /// 같은 실패를 초당 수십 번 찍지 않는다.
    private func logOnce(_ message: String) {
        lock.lock()
        let isNew = loggedMessages.insert(message).inserted
        lock.unlock()
        if isNew {
            NSLog("[Delight] %@", message)
            let line = "[매트] " + message + "\n"
            if let data = line.data(using: .utf8),
               let handle = FileHandle(forWritingAtPath: "/tmp/delight_status.log") {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            }
        }
    }

    /// 최신 매트. 아직 없으면 nil — 호출부는 깊이 기반 근사로 폴백한다.
    func latestTexture() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return ring.last?.texture
    }
}
