//
//  MetalPreviewView.swift
//  재조명 결과를 창에 그린다. 그게 전부다.
//
//  ⚠️ draw(in:)은 메인 스레드 보장이 없다.
//  @Observable 엔진을 여기서 직접 읽으면 참조카운트 경쟁으로 EXC_BAD_ACCESS가 난다
//  (크래시 리포트: RefCounts::incrementSlow). 그래서 FrameStore(nonisolated + 락)만 읽는다.
//

import SwiftUI
import MetalKit

struct MetalPreviewView: NSViewRepresentable {
    let engine: RelightEngine

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

    func updateNSView(_ view: MTKView, context: Context) { }

    /// 렌더 스레드에서 도는 델리게이트. 메인 액터 격리가 없다.
    nonisolated final class Coordinator: NSObject, MTKViewDelegate {
        private let frameStore: FrameStore
        private let commandQueue: MTLCommandQueue?
        private let compositePSO: MTLComputePipelineState?

        init(device: MTLDevice, frameStore: FrameStore) {
            self.frameStore = frameStore
            self.commandQueue = device.makeCommandQueue()
            if let library = device.makeDefaultLibrary(),
               let function = library.makeFunction(name: "present_mirrored") {
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

            // 재조명 결과가 있으면 그것을, 아직 없으면 원본 카메라를 보여준다.
            let (camera, relit) = frameStore.latest()
            guard let source = relit ?? camera else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(compositePSO)
                encoder.setTexture(source, index: 0)
                encoder.setTexture(drawable.texture, index: 1)
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
