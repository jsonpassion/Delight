//
//  PreviewSink.swift
//  앱 창에 그리는 싱크. 항상 켜 둔다 — 다른 경로가 전부 막혀도 데모는 된다.
//

import Metal
import CoreMedia

final class PreviewSink: FrameSink {
    let name = "프리뷰"
    var isActive: Bool { true }

    /// 최신 프레임. 렌더 루프가 읽어 간다.
    private(set) var latest: MTLTexture?

    func submit(_ texture: MTLTexture, pts: CMTime) {
        latest = texture
    }
}
