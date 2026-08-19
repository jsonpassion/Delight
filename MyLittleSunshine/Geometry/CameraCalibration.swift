//
//  CameraCalibration.swift
//  macOS는 카메라 내부파라미터를 주지 않는다 — 실측으로 확인한 하드 제약.
//
//    AVCaptureDeviceFormat.videoFieldOfView              → API_UNAVAILABLE(macos)
//    AVCaptureConnection.cameraIntrinsicMatrixDelivery*  → API_UNAVAILABLE(macos)
//
//  그래서 초점거리를 추정한다. 핵심은 정확도가 아니라 **불변성**이다.
//  fx가 20% 틀려도 사람은 모르지만, 프레임마다 변하면 즉시 티가 난다.
//  (docs/01-architecture.md §4)
//

import CoreGraphics
import Foundation

struct CameraCalibration {

    /// 픽셀 단위 초점거리와 주점.
    private(set) var fx: Float
    private(set) var fy: Float
    private(set) var cx: Float
    private(set) var cy: Float
    private(set) var isLocked = false

    /// 성인 평균 동공간거리(IPD). 얼굴 기반 캘리브레이션의 기준자.
    static let averageIPDMeters: Float = 0.063
    /// 웹캠 앞 사람의 거리 사전지식. 중앙값 기준.
    static let assumedSubjectDistance: Float = 0.60
    /// 폴백 가정 — 맥 내장/일반 웹캠은 대체로 수평 화각 55~65°.
    static let fallbackHorizontalFOV: Float = 60 * .pi / 180

    private var samples: [Float] = []
    private static let requiredSamples = 90   // 30fps에서 약 3초

    init(width: Int, height: Int) {
        let w = Float(width), h = Float(height)
        self.cx = w / 2
        self.cy = h / 2
        self.fx = (w / 2) / tan(Self.fallbackHorizontalFOV / 2)
        self.fy = self.fx
    }

    /// 얼굴 랜드마크에서 얻은 동공간 픽셀거리로 fx를 추정한다.
    /// 3초치 중앙값을 모은 뒤 **고정하고 다시는 바꾸지 않는다.**
    mutating func observe(interpupillaryPixels: Float) {
        guard !isLocked, interpupillaryPixels > 1 else { return }

        let estimate = interpupillaryPixels * Self.assumedSubjectDistance / Self.averageIPDMeters
        samples.append(estimate)

        guard samples.count >= Self.requiredSamples else { return }
        samples.sort()
        fx = samples[samples.count / 2]
        fy = fx
        isLocked = true
        samples.removeAll()
    }

    /// 사용자 슬라이더용. 물리적으로는 fx지만 사용자에겐 "조명 원근"이다.
    mutating func overrideFocalLength(_ value: Float) {
        fx = value
        fy = value
        isLocked = true
    }

    /// 정규화 화면좌표 + 역깊이 → 뷰공간 위치.
    func unproject(normalized uv: CGPoint, inverseDepth: Float,
                   affineA: Float, affineB: Float,
                   pixelWidth: Float, pixelHeight: Float) -> SIMD3<Float> {
        let z = 1.0 / max(affineA * inverseDepth + affineB, 1e-4)
        let u = Float(uv.x) * pixelWidth
        let v = Float(uv.y) * pixelHeight
        return SIMD3<Float>((u - cx) / fx * z, (v - cy) / fy * z, z)
    }
}
