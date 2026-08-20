//
//  ContentView.swift
//  화면은 하나다 — 영상과, 지금 무슨 일이 일어나는지 알려주는 한 줄.
//
//  조작 버튼을 두지 않는 이유: 이 앱이 하는 일은 하나다.
//  카메라를 켜고, 핀치로 조명을 옮기고, 그 결과를 내보낸다.
//  파라미터 슬라이더는 개발 중에 필요했지만 쓰는 사람에게는 선택지가 아니라 부담이다.
//

import SwiftUI

struct ContentView: View {
    @Environment(RelightEngine.self) private var engine
    @State private var previewSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            MetalPreviewView(engine: engine)

            switch engine.status {
            case .idle:              startOverlay
            case .failed(let text):  errorOverlay(text)
            case .running:           statusPill
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
        .contentShape(Rectangle())
        .gesture(
            // 손이 안 잡히는 상황에서도 데모가 죽지 않게 하는 유일한 장치.
            DragGesture(minimumDistance: 0)
                .onChanged { moveLight(to: $0.location, in: previewSize) }
        )
        .ignoresSafeArea()
    }

    // MARK: 오버레이

    private var startOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.max").font(.system(size: 46, weight: .ultraLight))
            Text("Delight").font(.title2.weight(.medium))
            Text("엄지와 검지를 붙이면 조명을 잡습니다")
                .font(.callout).foregroundStyle(.secondary)
            Button("시작") { engine.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .foregroundStyle(.white)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34, weight: .light))
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("다시 시도") { engine.start() }
        }
        .foregroundStyle(.white)
        .padding()
    }

    /// 상태 한 줄. 지금 조명을 잡고 있는지, 어디로 나가는지만 보여준다.
    private var statusPill: some View {
        HStack(spacing: 12) {
            Label(engine.pinch.isPinching ? "조명을 잡았습니다"
                                          : (engine.isHandVisible ? "핀치하세요" : "손을 보여주세요"),
                  systemImage: engine.pinch.isPinching ? "hand.pinch.fill" : "hand.raised")
                .foregroundStyle(engine.pinch.isPinching ? .orange : .primary)

            Divider().frame(height: 12)

            Toggle(isOn: Binding(get: { engine.isBroadcasting },
                                 set: { engine.isBroadcasting = $0 })) {
                Label("송출", systemImage: "dot.radiowaves.left.and.right")
            }
            .toggleStyle(.button)
            .help("OBS의 Syphon Client에서 \"Delight\"를 선택하세요.")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 22)
    }

    // MARK: 입력

    /// 뷰 좌표 → 프리뷰 정규화 좌표.
    /// 프리뷰가 거울상이므로 x를 뒤집는다. **핀치는 뒤집지 않는다** —
    /// 핀치 좌표와 렌더링이 둘 다 원본 카메라 좌표계이고 프리뷰에서 함께 뒤집히기 때문이다.
    private func moveLight(to point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = 1 - Float(min(max(point.x / size.width, 0), 1))
        let y = Float(min(max(point.y / size.height, 0), 1))
        engine.moveLight(toNormalized: SIMD2<Float>(x, y))
    }
}
