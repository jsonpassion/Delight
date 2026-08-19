//
//  ContentView.swift
//

import SwiftUI

struct ContentView: View {
    @Environment(RelightEngine.self) private var engine
    @State private var splitFraction: Float = 0.5

    var body: some View {
        @Bindable var engine = engine

        HSplitView {
            ZStack(alignment: .bottom) {
                Color.black
                MetalPreviewView(engine: engine, splitFraction: splitFraction)

                if case .idle = engine.status { startOverlay }
                if case .failed(let message) = engine.status { errorOverlay(message) }

                if engine.status == .running && engine.showDepth {
                    splitControl
                }
            }
            .frame(minWidth: 640)

            ControlPanel()
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 380)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle("반전", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                       isOn: $engine.isMirrored)
                    .help("거울상 프리뷰입니다. 송출 영상에는 적용되지 않습니다.")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("깊이", systemImage: "square.righthalf.filled", isOn: $engine.showDepth)
                    .help("카메라 옆에 실시간 깊이맵을 보여줍니다.")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("입력", selection: $engine.inputMode) {
                    ForEach(RelightEngine.InputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("손 인식이 불안정하면 마우스로 전환하세요.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(engine.status == .running ? "정지" : "시작") {
                    engine.status == .running ? engine.stop() : engine.start()
                }
            }
        }
    }

    private var splitControl: some View {
        HStack(spacing: 10) {
            Text("카메라").font(.caption2)
            Slider(value: $splitFraction, in: 0...1).frame(width: 180)
            Text("깊이").font(.caption2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 16)
    }

    private var startOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.max").font(.system(size: 44, weight: .light))
            Text("카메라를 시작하세요").font(.title3)
            Text("핀치로 조명을 잡아 옮길 수 있습니다.")
                .font(.callout).foregroundStyle(.secondary)
            Button("시작") { engine.start() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34, weight: .light))
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("다시 시도") { engine.start() }
        }
        .foregroundStyle(.white)
        .padding()
    }
}
