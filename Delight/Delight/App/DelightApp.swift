//
//  DelightApp.swift
//  Delight — 손으로 잡는 조명
//

import SwiftUI

/// 종료 시 캡처 세션을 먼저 내린다.
/// 세션이 살아있는 채로 프로세스가 exit하면 CoreMediaIO 정리 중 세그폴트가 난다
/// (크래시 리포트: CMIO::DAL::Object::Teardown).
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: RelightEngine?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { engine?.stop() }
    }
}

@main
struct DelightApp: App {
    @State private var engine = RelightEngine()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Delight", id: "main") {
            ContentView()
                .environment(engine)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { appDelegate.engine = engine }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environment(engine)
        }
    }
}
