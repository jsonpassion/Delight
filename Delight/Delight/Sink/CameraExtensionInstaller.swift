//
//  CameraExtensionInstaller.swift
//  CMIO 카메라 확장 설치 요청.
//
//  Syphon과 달리 이 경로는 OBS 없이 Zoom에 직접 나타난다.
//  대신 설치에 조건이 붙는다 — 아래 requirements 참조.
//

import Foundation
import SystemExtensions
import os

@Observable
@MainActor
final class CameraExtensionInstaller: NSObject {

    enum State: Equatable {
        case unknown
        case installing
        case needsApproval
        case installed
        case failed(String)
    }

    private(set) var state: State = .unknown
    static let bundleIdentifier = "forgelab.aitech-gmail.com.Delight.Camera"

    /// 설치가 가능한 상태인지 미리 알려준다.
    /// 실패한 뒤 로그를 뒤지는 것보다 미리 아는 편이 낫다.
    struct Requirements {
        var runningFromApplications: Bool
        var hasDeveloperIDSignature: Bool

        var blockingReasons: [String] {
            var reasons: [String] = []
            if !runningFromApplications {
                reasons.append("앱이 /Applications에 있어야 합니다 (현재는 빌드 폴더에서 실행 중).")
            }
            if !hasDeveloperIDSignature {
                reasons.append("Developer ID 서명이 필요합니다. 개발 중에는 SIP를 끄고 "
                             + "`systemextensionsctl developer on`을 켜야 Apple Development 서명으로 설치됩니다.")
            }
            return reasons
        }
    }

    static func currentRequirements() -> Requirements {
        let path = Bundle.main.bundlePath
        return Requirements(
            runningFromApplications: path.hasPrefix("/Applications/"),
            // 정확한 판정은 codesign 검사가 필요하다. 여기서는 보수적으로 본다 —
            // 개발 빌드는 Apple Development 서명이므로 false로 두고 안내를 띄운다.
            hasDeveloperIDSignature: false)
    }

    func install() {
        state = .installing
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension CameraExtensionInstaller: OSSystemExtensionRequestDelegate {

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // 확장은 세션 중 라이브 교체가 안 된다. 교체는 재부팅 후에 반영된다.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .needsApproval
            NSLog("[Delight] 확장 승인 대기 — 시스템 설정 → 일반 → 로그인 항목 및 확장")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.state = .installed
            NSLog("[Delight] 확장 설치 결과: %d (재부팅이 필요할 수 있습니다)", result.rawValue)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            NSLog("[Delight] 확장 설치 실패: %@", error.localizedDescription)
        }
    }
}
