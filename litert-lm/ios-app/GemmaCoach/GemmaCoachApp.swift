// GemmaCoachApp.swift
// Gemma 4 E2B running coach demo, powered by LiteRT-LM via the LiteRTLM-Swift package.

import SwiftUI

@main
struct GemmaCoachApp: App {
    @StateObject private var engineModel = EngineModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engineModel)
        }
    }
}
