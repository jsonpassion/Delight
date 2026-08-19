//
//  ContentView.swift
//

import SwiftUI

struct ContentView: View {
    @Environment(RelightEngine.self) private var engine

    var body: some View {
        @Bindable var engine = engine

        HSplitView {
            ZStack {
                Color.black
                MetalPreviewView(engine: engine)

                if case .idle = engine.status {
                    startOverlay
                }
                if case .failed(let message) = engine.status {
                    errorOverlay(message)
                }
            }
            .frame(minWidth: 640)

            ControlPanel()
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 380)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("입력", selection: $engine.inputMode) {
                    ForEach(RelightEngine.InputMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
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

    private var startOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.max")
                .font(.system(size: 44, weight: .light))
            Text("카메라를 시작하세요")
                .font(.title3)
            Text("핀치로 조명을 잡아 옮길 수 있습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("시작") { engine.start() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("다시 시도") { engine.start() }
        }
        .foregroundStyle(.white)
        .padding()
    }
}
