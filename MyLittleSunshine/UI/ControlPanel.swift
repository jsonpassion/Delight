//
//  ControlPanel.swift
//  파라미터를 눈으로 돌려보는 패널. 튜닝 속도가 곧 품질이다.
//

import SwiftUI

struct ControlPanel: View {
    @Environment(RelightEngine.self) private var engine

    var body: some View {
        @Bindable var rig = engine.lightRig

        Form {
            Section("상태") {
                LabeledContent("파이프라인", value: statusText)
                LabeledContent("FPS", value: String(format: "%.1f", engine.stats.fps))
                LabeledContent("프레임", value: "\(engine.stats.frameCount)")
            }

            Section("조명") {
                if rig.active != nil {
                    Slider(value: Binding(
                        get: { rig.active?.intensity ?? 0 },
                        set: { rig.active?.intensity = $0 }
                    ), in: 0...4) { Text("세기") }

                    Slider(value: Binding(
                        get: { rig.active?.radius ?? 0 },
                        set: { rig.active?.radius = $0 }
                    ), in: 0.01...0.3) { Text("반경") }
                }
            }

            Section("레이마칭") {
                Slider(value: $rig.personThickness, in: 0.02...0.4) { Text("사람 두께") }
                    .help("너무 크면 배경이 검게 죽고, 너무 작으면 그림자가 안 생깁니다.")
                Slider(value: $rig.backgroundThickness, in: 0.01...0.2) { Text("배경 두께") }
                Stepper("스텝 \(rig.raymarchSteps)", value: $rig.raymarchSteps, in: 8...48, step: 4)
            }

            Section("셰이딩") {
                Toggle("앰비언트 오클루전", isOn: $rig.ambientOcclusionEnabled)
                Toggle("스펙큘러", isOn: $rig.specularEnabled)
                Slider(value: $rig.skinRoughness, in: 0.2...0.8) { Text("피부 거칠기") }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch engine.status {
        case .idle:    return "대기"
        case .running: return "실행 중"
        case .failed:  return "오류"
        }
    }
}
