//
//  DepthProvider.swift
//  추론 백엔드 추상화. Metal 4 ML(기본)과 Core ML/ANE(폴백)를 교체할 수 있어야 한다.
//
//  M5 실측 (518×392, 40회 median):
//    MTL4MachineLearningCommandEncoder  15.42 ms   ← 기본
//    Core ML .all (ANE)                 20.78 ms   ← GPU가 렌더로 포화될 때의 탈출구
//    Core ML .cpuOnly                   45.10 ms
//

import Metal
import Foundation

/// 모델의 고정 입출력 크기. Depth Anything V2-small Core ML 배포판 기준.
enum DepthModelSpec {
    static let width  = 518
    static let height = 392

    /// MTLTensorUsageMachineLearning이면 strides[1]이 64바이트 정렬이어야 한다.
    /// f32 518열 = 2072B → 2112B(528 elem)로 패딩된다.
    /// **셰이더는 이 행 패딩을 반드시 계산에 넣어야 한다.**
    static func rowStride(elementBytes: Int) -> Int {
        ((width * elementBytes + 63) / 64) * 64 / elementBytes
    }
}

protocol DepthProvider: AnyObject {
    var name: String { get }
    /// 출력 역깊이 버퍼. 행 패딩 포함.
    var depthBuffer: MTLBuffer? { get }
    var rowStride: Int { get }

    /// 커맨드 버퍼에 추론을 인코딩한다. CPU 동기화 없이 다음 스테이지가 결과를 읽는다.
    func encode(into commandBuffer: MTL4CommandBuffer, argumentTable: MTL4ArgumentTable) throws
}
