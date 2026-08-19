//
//  MetalPreviewView.swift
//  MTKView를 SwiftUI에 붙인다. 최종 합성 결과를 그린다.
//

import SwiftUI
import MetalKit

struct MetalPreviewView: NSViewRepresentable {
    let engine: RelightEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: engine.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        view.layer?.isOpaque = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) { }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let engine: RelightEngine
        private let previewSink = PreviewSink()
        private let commandQueue: MTLCommandQueue?

        init(engine: RelightEngine) {
            self.engine = engine
            self.commandQueue = engine.device.makeCommandQueue()
            super.init()
            engine.attach(sink: previewSink)
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                guard let drawable = view.currentDrawable,
                      let commandQueue,
                      let commandBuffer = commandQueue.makeCommandBuffer() else { return }

                if let source = previewSink.latest,
                   let blit = commandBuffer.makeBlitCommandEncoder() {
                    // P1: 캡처 텍스처를 그대로 보여준다.
                    // P2 이후 여기가 리라이팅 결과 텍스처로 바뀐다.
                    let width  = min(source.width,  drawable.texture.width)
                    let height = min(source.height, drawable.texture.height)
                    blit.copy(from: source,
                              sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: width, height: height, depth: 1),
                              to: drawable.texture,
                              destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }

                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }
    }
}
