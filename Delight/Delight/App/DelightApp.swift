//
//  DelightApp.swift
//  Delight — 손으로 잡는 조명
//

import SwiftUI

@main
struct DelightApp: App {
    @State private var engine = RelightEngine()

    var body: some Scene {
        Window("Delight", id: "main") {
            ContentView()
                .environment(engine)
                .frame(minWidth: 960, minHeight: 640)
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
