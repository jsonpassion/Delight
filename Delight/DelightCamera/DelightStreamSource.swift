//
//  DelightStreamSource.swift
//  출력 스트림. 소비자(Zoom 등)가 붙으면 장치에 스트리밍 시작을 알린다.
//

import Foundation
import CoreMediaIO

class DelightStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var device: CMIOExtensionDevice?

    init(localizedName: String, streamID: UUID,
         streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.streamFormat = streamFormat
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet { if activeFormatIndex != 0 { extensionLog.error("잘못된 포맷 인덱스") } }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            self.activeFormatIndex = index
        }
    }

    /// 아무 클라이언트나 붙을 수 있게 한다. 화상회의 앱을 화이트리스트로 관리하면
    /// 새 앱이 나올 때마다 못 쓴다.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard let deviceSource = device?.source as? DelightDeviceSource else { return }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device?.source as? DelightDeviceSource else { return }
        deviceSource.stopStreaming()
    }
}
