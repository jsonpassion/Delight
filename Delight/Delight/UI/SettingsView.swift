//
//  SettingsView.swift
//

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(RelightEngine.self) private var engine
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section("카메라") {
                ForEach(cameras, id: \.uniqueID) { camera in
                    LabeledContent(camera.localizedName, value: camera.deviceType.rawValue)
                        .font(.callout)
                }
                if cameras.isEmpty {
                    Text("카메라를 찾지 못했습니다.").foregroundStyle(.secondary)
                }
            }

            Section("Zoom으로 내보내기") {
                Text("툴바의 **송출**을 켜면 Syphon 서버로 나갑니다.")
                    .font(.callout)
                LabeledContent("서버 이름", value: SyphonSink.serverName)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. OBS에서 소스 → Syphon Client 추가 → \"Delight\" 선택")
                    Text("2. OBS 하단 **가상 카메라 시작**")
                    Text("3. Zoom을 **나중에** 실행 — 시작 시 한 번만 장치를 스캔합니다")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
        .task { cameras = CameraCapture.availableCameras() }
    }
}
