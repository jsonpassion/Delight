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
                LabeledContent("캡처", value: String(format: "%.1f fps", engine.stats.captureFPS))
                LabeledContent("깊이 추론", value: String(format: "%.2f ms", engine.stats.depthMilliseconds))
                    .help("M5 기준선 15.4 ms. 크게 벗어나면 회귀를 의심하세요.")
                LabeledContent("깊이 처리율", value: String(format: "%.1f fps", engine.stats.depthFPS))
                LabeledContent("프레임", value: "\(engine.stats.frameCount)")
            }

            Section("조명 위치") {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $rig.depthOffset,
                           in: LightRig.nearestOffset...LightRig.farthestOffset) {
                        Text("앞 ↔ 뒤")
                    } minimumValueLabel: {
                        Image(systemName: "person.fill").font(.caption2)
                    } maximumValueLabel: {
                        Image(systemName: "sun.max.fill").font(.caption2)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: rig.isBehindSubject ? "sun.haze.fill" : "lightbulb.fill")
                            .foregroundStyle(rig.isBehindSubject ? .orange : .yellow)
                        Text(rig.isBehindSubject
                             ? String(format: "역광 %.0f%% — 피사체가 빛을 가립니다", rig.backlightAmount * 100)
                             : "정면광")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                if rig.active != nil {
                    Slider(value: Binding(get: { rig.active?.intensity ?? 0 },
                                          set: { rig.active?.intensity = $0 }),
                           in: 0...4) { Text("세기") }

                    Slider(value: Binding(get: { rig.active?.radius ?? 0 },
                                          set: { rig.active?.radius = $0 }),
                           in: 0.01...0.3) { Text("광원 반경") }
                        .help("클수록 그림자 경계가 부드러워집니다(페넘브라).")
                }
            }

            Section("레이마칭") {
                Slider(value: $rig.personThickness, in: 0.02...0.4) { Text("사람 두께") }
                    .help("가장 위험한 파라미터. 크면 배경이 검게 죽고, 작으면 그림자가 안 생깁니다.")
                Slider(value: $rig.backgroundThickness, in: 0.01...0.2) { Text("배경 두께") }
                Stepper("스텝 \(rig.raymarchSteps)", value: $rig.raymarchSteps, in: 8...48, step: 4)
            }

            Section("셰이딩") {
                Toggle("앰비언트 오클루전", isOn: $rig.ambientOcclusionEnabled)
                Toggle("스펙큘러", isOn: $rig.specularEnabled)
                Slider(value: $rig.skinRoughness, in: 0.2...0.8) { Text("피부 거칠기") }
                Slider(value: $rig.wrapDiffuse, in: 0...0.8) { Text("표면하 감쌈") }
                    .help("피부는 표면 아래 산란 때문에 명암 경계가 부드럽습니다.")
            }

            Section("역광") {
                Slider(value: $rig.rimPower, in: 1...8) { Text("림 날카로움") }
                Slider(value: $rig.translucency, in: 0...1.5) { Text("투과 산란") }
                    .help("귀·머리카락처럼 얇은 부위로 빛이 새어 나오는 정도입니다.")
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
