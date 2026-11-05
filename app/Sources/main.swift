// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

struct ManagerApp: App {
    @StateObject var manager = Manager()
    var body: some Scene {
        WindowGroup("IntelXe Manager") {
            RootView().environmentObject(manager)
        }
        .windowToolbarStyle(.unified)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

if CommandLine.arguments.contains("--selftest") {
    selfTest()
} else {
    ManagerApp.main()
}
