//
//  SyphonSink.swift
//  Syphon 서버로 IOSurface 텍스처를 publish → OBS Syphon Client → OBS 가상카메라 → Zoom.
//
//  이 경로가 데모 1순위인 이유: 서명·공증·시스템확장·재부팅이 전부 불필요하다.
//  OBS의 카메라 확장은 이미 서명·공증되어 있다. (docs/00-feasibility.md §3 경로 2)
//
//  P5에서 Syphon.framework를 링크하고 아래 TODO를 채운다.
//

import Metal
import CoreMedia

final class SyphonSink: FrameSink {
    let name = "Syphon"
    private(set) var isActive = false

    // TODO(P5): SyphonMetalServer 인스턴스. Syphon.framework 링크 후 활성화.
    // private var server: SyphonMetalServer?

    func start() {
        // TODO(P5): server = SyphonMetalServer(name: "My Little Sunshine", device: device, ...)
        isActive = false
    }

    func stop() {
        isActive = false
    }

    func submit(_ texture: MTLTexture, pts: CMTime) {
        guard isActive else { return }
        // TODO(P5): server?.publishFrameTexture(texture, ...)
    }
}
