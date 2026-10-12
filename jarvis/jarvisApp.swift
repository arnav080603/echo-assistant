//
//  jarvisApp.swift
//  jarvis
//
//  Created by Arnav Sharma on 7/1/26.
//

import SwiftUI

@main
struct jarvisApp: App {
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 660)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif

        #if os(macOS)
        MenuBarExtra("ECHO", systemImage: "circle.hexagongrid.circle") {
            MenuBarView()
        }
        #endif
    }
}
