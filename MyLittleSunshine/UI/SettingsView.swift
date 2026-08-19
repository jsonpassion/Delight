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

            Section("출력") {
                Text("Syphon 출력은 P5에서 활성화됩니다. OBS의 Syphon Client 소스로 받아 가상카메라로 송출하세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
        .task { cameras = CameraCapture.availableCameras() }
    }
}
