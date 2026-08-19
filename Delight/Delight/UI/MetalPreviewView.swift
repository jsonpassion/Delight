//
//  MetalPreviewView.swift
//  MTKView를 SwiftUI에 붙여 카메라·재조명 결과·깊이맵을 보여준다.
//
//  ⚠️ draw(in:)은 메인 스레드 보장이 없다.
//  @Observable 엔진을 여기서 직접 읽으면 참조카운트 경쟁으로 EXC_BAD_ACCESS가 난다
//  (실제 크래시 리포트로 확인: RefCounts::incrementSlow).
//  그래서 렌더에 필요한 값은 메인 액터에서 미리 스냅샷해 락으로 보호된 저장소에 넣고,
//  draw는 그 스냅샷과 FrameStore(둘 다 nonisolated)만 읽는다.
//

import SwiftUI
import MetalKit

/// 메인 액터가 쓰고 렌더 스레드가 읽는 렌더 파라미터.
nonisolated final class RenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var _splitFraction: Float = 0.5
    private var _mirrored = true
    private var _showDepth = true
    private var _showRelit = true

    func update(splitFraction: Float, mirrored: Bool, showDepth: Bool, showRelit: Bool) {
        lock.lock()
        _splitFraction = splitFraction
        _mirrored = mirrored
        _showDepth = showDepth
        _showRelit = showRelit
        lock.unlock()
    }

    func snapshot() -> (split: Float, mirrored: Bool, showDepth: Bool, showRelit: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_splitFraction, _mirrored, _showDepth, _showRelit)
    }
}

struct MetalPreviewView: NSViewRepresentable {
    let engine: RelightEngine
    var splitFraction: Float

    func makeCoordinator() -> Coordinator {
        Coordinator(device: engine.device, frameStore: engine.frameStore)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: engine.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false          // 컴퓨트 셰이더가 드로어블에 쓴다
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = context.coordinator
        view.layer?.isOpaque = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderState.update(
            splitFraction: splitFraction,
            mirrored: engine.isMirrored,
            showDepth: engine.showDepth,
            showRelit: engine.showRelit)
    }

    /// 렌더 스레드에서 도는 델리게이트. 메인 액터 격리가 없다.
    nonisolated final class Coordinator: NSObject, MTKViewDelegate {
        let renderState = RenderState()
        private let frameStore: FrameStore
        private let commandQueue: MTLCommandQueue?
        private let compositePSO: MTLComputePipelineState?

        init(device: MTLDevice, frameStore: FrameStore) {
            self.frameStore = frameStore
            self.commandQueue = device.makeCommandQueue()
            if let library = device.makeDefaultLibrary(),
               let function = library.makeFunction(name: "composite_split") {
                self.compositePSO = try? device.makeComputePipelineState(function: function)
            } else {
                self.compositePSO = nil
            }
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandQueue,
                  let compositePSO,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let state = renderState.snapshot()
            let (camera, depth, relit) = frameStore.latest()

            // 재조명 결과가 있으면 그것을, 없으면 원본 카메라를 보여준다.
            let primary = (state.showRelit ? relit : nil) ?? camera ?? depth
            guard let primary else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            // 깊이가 아직 없으면 왼쪽만 꽉 채운다.
            var split = (depth != nil && state.showDepth) ? state.split : 1.0
            var mirrored: UInt32 = state.mirrored ? 1 : 0

            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(compositePSO)
                encoder.setTexture(primary, index: 0)
                encoder.setTexture(depth ?? primary, index: 1)
                encoder.setTexture(drawable.texture, index: 2)
                encoder.setBytes(&split, length: MemoryLayout<Float>.size, index: 0)
                encoder.setBytes(&mirrored, length: MemoryLayout<UInt32>.size, index: 1)
                encoder.dispatchThreads(
                    MTLSize(width: drawable.texture.width, height: drawable.texture.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding()
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
