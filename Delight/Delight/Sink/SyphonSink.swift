//
//  SyphonSink.swift
//  Syphon 서버로 IOSurface 텍스처를 publish → OBS Syphon Client → OBS 가상카메라 → Zoom.
//
//  이 경로가 데모 1순위인 이유: 서명·공증·시스템확장·재부팅이 전부 불필요하다.
//  OBS의 카메라 확장은 이미 서명·공증되어 있어 우리는 텍스처만 넘기면 된다.
//  (docs/00-feasibility.md §3 경로 2)
//
//  Syphon은 프레임워크 임베드 대신 **소스를 앱 타깃에 포함**했다 — Syphon/ 폴더 참조.
//

import Metal
import CoreMedia
import Foundation

final class SyphonSink: FrameSink {
    let name = "Syphon"
    private(set) var isActive = false

    /// Syphon 클라이언트(OBS 등)에 표시되는 이름.
    static let serverName = "Delight"

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private var server: SyphonMetalServer?

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
    }

    func start() {
        guard server == nil else { isActive = true; return }
        guard let commandQueue else {
            NSLog("[Delight] Syphon: 커맨드 큐 생성 실패")
            return
        }
        // 서버는 device만 받는다. 프레임 복사는 우리가 넘긴 커맨드 버퍼에 인코딩된다 —
        // 전용 큐를 따로 두어 publish가 렌더 큐를 막지 않게 한다.
        _ = commandQueue
        server = SyphonMetalServer(name: Self.serverName, device: device, options: nil)
        isActive = server != nil
        NSLog("[Delight] Syphon 서버 %@: %@", isActive ? "시작됨" : "시작 실패", Self.serverName)
    }

    func stop() {
        server?.stop()
        server = nil
        isActive = false
    }

    func submit(_ texture: MTLTexture, pts: CMTime) {
        guard isActive, let server, let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // 전체 프레임을 그대로 내보낸다. 뒤집지 않는다 —
        // 거울상은 프리뷰 전용이고, 송출은 비반전이 정석이다.
        let region = NSRect(x: 0, y: 0, width: texture.width, height: texture.height)
        server.publishFrameTexture(texture,
                                   on: commandBuffer,
                                   imageRegion: region,
                                   flipped: false)
        commandBuffer.commit()
    }

    /// 현재 시스템에 등록된 Syphon 서버 목록. 진단용.
    static func announcedServers() -> [String] {
        SyphonServerDirectory.shared().servers.compactMap {
            $0[SyphonServerDescriptionNameKey] as? String
        }
    }
}
