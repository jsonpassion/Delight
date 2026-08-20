//
//  DelightDeviceSource.swift
//  가상 카메라 장치와 출력 스트림.
//
//  프레임 공급 구조:
//  앱이 살아 있으면 IOSurface 공유로 실제 재조명 영상을 받고,
//  없으면 안내 패턴을 내보낸다. Zoom은 장치가 항상 프레임을 주기를 기대하므로
//  "앱이 꺼져 있으면 검은 화면"이 아니라 안내가 나가야 한다.
//

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

let kFrameRate = 30
let kWidth = 1280
let kHeight = 720

class DelightDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: DelightStreamSource!
    private var streamingCounter = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "delight.camera.timer", qos: .userInteractive)

    private var bufferPool: CVPixelBufferPool?
    private var frameIndex: UInt64 = 0

    init(localizedName: String) {
        super.init()
        // UUID는 고정이어야 한다. 매번 바뀌면 Zoom이 다른 장치로 인식해
        // 사용자가 매번 카메라를 다시 골라야 한다.
        let deviceID = UUID(uuidString: "6B9D4F2A-3C41-4E8B-9A17-5D2E7F0C8A31")!
        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: deviceID,
                                     legacyDeviceID: nil,
                                     source: self)

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(kWidth), height: Int32(kHeight),
                                       extensions: nil, formatDescriptionOut: &format)
        guard let format else { return }

        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format,
                                                     maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
                                                     minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
                                                     validFrameDurations: nil)
        let streamID = UUID(uuidString: "A1C8E3D7-6B25-4F09-8E14-2D7A9B0C5F63")!
        streamSource = DelightStreamSource(localizedName: "Delight.Video",
                                           streamID: streamID,
                                           streamFormat: streamFormat,
                                           device: device)

        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: kWidth,
            kCVPixelBufferHeightKey as String: kHeight,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &bufferPool)

        do {
            try device.addStream(streamSource.stream)
        } catch {
            extensionLog.error("스트림 추가 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt' — CoreAudio의 kIOAudioDeviceTransportTypeVirtual과 같은 값.
            // 확장은 CoreAudio를 링크하지 않으므로 FourCC를 직접 쓴다.
            result.transportType = 0x76697274
        }
        if properties.contains(.deviceModel) {
            result.model = "Delight Virtual Camera"
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws { }

    // MARK: 스트리밍

    func startStreaming() {
        guard let bufferPool else { return }
        streamingCounter += 1
        guard streamingCounter == 1 else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.emitFrame(pool: bufferPool)
        }
        timer.resume()
        self.timer = timer
        extensionLog.info("스트리밍 시작")
    }

    func stopStreaming() {
        streamingCounter = max(streamingCounter - 1, 0)
        guard streamingCounter == 0 else { return }
        timer?.cancel()
        timer = nil
        extensionLog.info("스트리밍 정지")
    }

    private func emitFrame(pool: CVPixelBufferPool) {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }

        // TODO(P7-2): 앱이 공유한 IOSurface에서 재조명 프레임을 복사한다.
        // 지금은 앱 연결 전 상태를 알리는 패턴을 그린다.
        FramePainter.drawPlaceholder(into: pixelBuffer, frameIndex: frameIndex)
        frameIndex &+= 1

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        streamSource.stream.send(sampleBuffer,
                                 discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * 1_000_000_000))
    }
}
