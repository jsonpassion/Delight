//
//  ContentView.swift
//

import SwiftUI

struct ContentView: View {
    @Environment(RelightEngine.self) private var engine
    @State private var splitFraction: Float = 0.5
    @State private var previewSize: CGSize = .zero

    var body: some View {
        @Bindable var engine = engine

        HSplitView {
            ZStack(alignment: .bottom) {
                Color.black
                MetalPreviewView(engine: engine, splitFraction: splitFraction)

                if case .idle = engine.status { startOverlay }
                if case .failed(let message) = engine.status { errorOverlay(message) }

                if engine.status == .running {
                    VStack(spacing: 10) {
                        if engine.inputMode == .hand { pinchIndicator }
                        if engine.showDepth { splitControl }
                    }
                }
            }
            .frame(minWidth: 640)
            // 크기는 레이아웃에 관여하지 않고 읽는다.
            // GeometryReader로 NSViewRepresentable을 감싸면 크기 협상이 재귀해 크래시한다.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in moveLight(to: value.location, in: previewSize) }
            )

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

    /// 핀치 상태 피드백. 손을 놓쳤는지, 잡았는지, 얼마나 깊은지 한눈에 보인다.
    private var pinchIndicator: some View {
        let pinch = engine.pinch
        let tracking = engine.handTracker?.isHandVisible ?? false
        return HStack(spacing: 10) {
            Image(systemName: pinch.isPinching ? "hand.pinch.fill" : "hand.raised")
                .foregroundStyle(pinch.isPinching ? .orange : (tracking ? .primary : .secondary))
            Text(pinch.isPinching ? "조명을 잡았습니다"
                                  : (tracking ? "핀치하면 조명을 잡습니다" : "손이 보이지 않습니다"))
                .font(.caption)
            if pinch.isPinching {
                Divider().frame(height: 12)
                Text(engine.lightRig.isBehindSubject
                     ? String(format: "역광 %.0f%%", engine.lightRig.backlightAmount * 100)
                     : "정면광")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// 뷰 좌표 → 프리뷰 정규화 좌표.
    /// 두 가지를 보정해야 손이 조명을 따라온다.
    ///  1) 좌우 분할 — 왼쪽(카메라) 패널 안에서의 상대 위치로 환산
    ///  2) 거울상 — 프리뷰가 반전이면 x를 뒤집는다
    /// 이 보정을 빠뜨리면 조명이 손 반대쪽으로 간다. 반드시 한 곳에서만 한다.
    private func moveLight(to point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // 손 모드에서도 드래그는 항상 먹는다. 데모 중 손 인식이 실패해도 죽지 않는 유일한 장치다.

        let split = (engine.showDepth && splitFraction > 0.001) ? CGFloat(splitFraction) : 1.0
        let paneWidth = max(size.width * split, 1)

        var x = Float(min(max(point.x / paneWidth, 0), 1))
        let y = Float(min(max(point.y / size.height, 0), 1))
        if engine.isMirrored { x = 1 - x }

        engine.moveLight(toNormalized: SIMD2<Float>(x, y))
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
