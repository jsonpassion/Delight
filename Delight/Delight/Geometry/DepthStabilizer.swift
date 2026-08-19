//
//  DepthStabilizer.swift
//  품질의 8할이 여기 있다. (docs/01-architecture.md §5)
//
//  1. affine 스케일 드리프트 — 상대깊이라 프레임마다 스케일이 흔들린다.
//     3D에 고정한 조명 기준으로 보면 씬 전체가 앞뒤로 펌핑한다.
//     해법: person matte **바깥**(배경)만으로 robust affine fit. 배경은 안 움직인다.
//  2. 플리커 — edge-stopping 시간필터. 색 가중치를 빼면 사람이 움직일 때 고스팅이 난다.
//  3. 업샘플 — bilinear로 올리면 실루엣이 뭉개져 그림자가 얼굴 밖으로 샌다.
//     joint bilateral(컬러 guide) + person matte 하드 컷.
//

import Foundation

struct DepthStabilizer {

    struct Parameters {
        /// 배경 기준 EMA 갱신률. 아주 느려야 앵커 역할을 한다.
        var referenceUpdateRate: Float = 0.02
        /// 시간필터 히스토리 비중.
        var temporalBlend: Float = 0.85
        /// 색 차이 허용폭. 크면 고스팅, 작으면 떨림.
        var colorSigma: Float = 0.08
        /// 깊이 차이 허용폭.
        var depthSigma: Float = 0.05
    }

    var parameters = Parameters()

    /// 현재 프레임을 기준 프레임에 맞추는 affine 계수 (a, b).
    private(set) var affineA: Float = 1
    private(set) var affineB: Float = 0

    /// 배경 픽셀 표본으로 robust affine fit. 중앙값 기반이라 RANSAC이 필요 없다.
    /// TODO(P6): GPU 리덕션으로 옮긴다. 지금은 인터페이스만 고정.
    mutating func fit(backgroundSamples current: [Float], reference: [Float]) {
        guard current.count == reference.count, current.count > 16 else { return }

        let medCur = median(current)
        let medRef = median(reference)
        let madCur = median(current.map { abs($0 - medCur) })
        let madRef = median(reference.map { abs($0 - medRef) })

        guard madCur > 1e-5 else { return }
        affineA = madRef / madCur
        affineB = medRef - affineA * medCur
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
