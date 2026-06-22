// BuddyApp.swift — SwiftUI macOS 27 entry point
// Requires: DEVELOPER_DIR=~/Downloads/Xcode-beta.app/Contents/Developer swift run BuddyApp

import SwiftUI

@main
struct BuddyApp: App {
    var body: some Scene {
        Window("Coworkers Buddy", id: "buddy") {
            BuddyWindow()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 500)
    }
}
