//
//  MetalPreviewView.swift
//  MTKView를 SwiftUI에 붙여 카메라와 깊이맵을 좌우로 보여준다.
//
//  DepthPipeline이 GPU 완료를 기다린 뒤에 텍스처를 publish하므로,
//  여기서 클래식 큐로 읽어도 경합이 없다.
//

import SwiftUI
import MetalKit

struct MetalPreviewView: NSViewRepresentable {
    let engine: RelightEngine
    var splitFraction: Float

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
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
        context.coordinator.splitFraction = splitFraction
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let engine: RelightEngine
        private let commandQueue: MTLCommandQueue?
        private let compositePSO: MTLComputePipelineState?
        var splitFraction: Float = 0.5

        init(engine: RelightEngine) {
            self.engine = engine
            self.commandQueue = engine.device.makeCommandQueue()
            if let library = engine.device.makeDefaultLibrary(),
               let function = library.makeFunction(name: "composite_split") {
                self.compositePSO = try? engine.device.makeComputePipelineState(function: function)
            } else {
                self.compositePSO = nil
            }
            super.init()
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                guard let drawable = view.currentDrawable,
                      let commandQueue,
                      let compositePSO,
                      let commandBuffer = commandQueue.makeCommandBuffer() else { return }

                let (camera, depth) = engine.frameStore.latest()
                let source = camera ?? depth
                guard let source else {
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                    return
                }

                // 깊이가 아직 없으면 카메라만 꽉 채워 보여준다.
                let effectiveSplit = (depth != nil && engine.showDepth) ? splitFraction : 1.0
                var split = effectiveSplit
                var mirrored: UInt32 = engine.isMirrored ? 1 : 0

                if let encoder = commandBuffer.makeComputeCommandEncoder() {
                    encoder.setComputePipelineState(compositePSO)
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(depth ?? source, index: 1)
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
}
