//
//  FrameSink.swift
//  엔진은 출력 경로가 무엇인지 몰라야 한다.
//  그래야 CMIO 확장이 서명 문제로 막혀도 프로젝트가 죽지 않는다.
//  (docs/00-feasibility.md §3)
//

import Metal
import CoreMedia

protocol FrameSink: AnyObject {
    var name: String { get }
    var isActive: Bool { get }
    func submit(_ texture: MTLTexture, pts: CMTime)
}
