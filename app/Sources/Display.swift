// SPDX-License-Identifier: MIT
// The Display page: HiDPI modes ("Larger Text ... More Space") for the monitor on the card, through hidpi.sh.
// hidpi.sh decides what is written (an NVRAM flag, a display override with the HiDPI sizes, WindowServer's
// DisplayResolutionEnabled) and takes back only what it wrote; the app shows its status and runs --on / --off as root.
import Foundation
import SwiftUI

/// hidpi.sh --status.
struct HiDPIStatus {
    var values: [String: String] = [:]
    init() {}
    init(text: String) {
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
    }
    subscript(key: String) -> String { values[key] ?? "" }
    var known: Bool { !values.isEmpty }
    /// The installed IntelXeFB offers scaled modes (0.1.3 on).
    var supported: Bool { self["hidpi_supported"] == "1" }
    /// --on has run: the NVRAM flag and this script's override.
    var on: Bool { self["hidpi_nvram"] == "1" && self["hidpi_override"] == "ours" }
    /// An override for this monitor that hidpi.sh did not write (another HiDPI tool's): hidpi.sh leaves it alone.
    var foreignOverride: Bool { self["hidpi_override"] == "other" }
    /// The framebuffer offers the scaled modes this boot.
    var active: Bool { self["hidpi_active"] == "1" }
    /// --on or --off ran but the machine has not restarted since.
    var pending: Bool { on != active }
}

/// The package's hidpi.sh, or the copy in this app (the same file) for packages made before it.
func hidpiScript(for package: Package?) -> URL? {
    if let own = package?.directory.appendingPathComponent("hidpi.sh"), FileManager.default.fileExists(atPath: own.path) { return own }
    return Bundle.main.url(forResource: "hidpi", withExtension: "sh")
}

func hidpiStatus(script: URL) -> HiDPIStatus {
    HiDPIStatus(text: commandOutput("/bin/bash", [script.path, "--status"], seconds: 30) ?? "")
}

enum HiDPIAction: String, Identifiable {
    case on, off
    var id: String { rawValue }
    var argument: String { self == .on ? "--on" : "--off" }
    var title: String {
        switch self {
        case .on: return String(localized: "Turn HiDPI modes on")
        case .off: return String(localized: "Turn HiDPI modes off")
        }
    }
}

extension Manager {
    func refreshHiDPI() async {
        guard let script = hidpiScript(for: package) else { hidpi = HiDPIStatus(); return }
        hidpi = await Task.detached { hidpiStatus(script: script) }.value
    }

    func performHiDPI(_ action: HiDPIAction) {
        guard let script = hidpiScript(for: package) else { return }
        perform(title: action.title, command: "/bin/bash \(shellQuoted(script.path)) \(action.argument)", needsRoot: true, then: { result in
            if result.cancelled {
                self.lastResult = String(localized: "Cancelled. Nothing changed.")
            } else if result.succeeded {
                self.lastResult = String(localized: "Finished. Restart to use the change.")
                self.rebootNeeded = true
            } else {
                self.lastResult = String(localized: "It did not finish. See the log.")
            }
        })
    }
}

struct DisplayView: View {
    @EnvironmentObject var manager: Manager
    var body: some View {
        let status = manager.hidpi
        Form {
            Section2(title: "HiDPI modes") {
                Text("Optional. Like display scaling on Windows: System Settings > Displays offers \"looks like\" sizes (Larger Text ... More Space) that draw text and windows sharp at a larger size, at the monitor's full refresh rate. They are scaled on the GPU.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if status.known {
                    LabeledContent("Monitor") { Text(monitorText(status)).textSelection(.enabled) }
                    LabeledContent("HiDPI modes") { Text(stateText(status)) }
                } else {
                    Text("Reading the display settings…").foregroundStyle(.secondary)
                }
            }
            if status.known {
                Section2(title: "Actions") {
                    if !status.supported {
                        Label("The installed driver has no HiDPI modes yet. Install release 0.1.3 or later first.", systemImage: "exclamationmark.triangle")
                    } else if status.foreignOverride {
                        Label("This monitor already has a display override from another tool (one-key-hidpi or similar). It is left as it is: remove it first to use this one.", systemImage: "exclamationmark.triangle")
                    }
                    if status.on {
                        Button(HiDPIAction.off.title, role: .destructive) { manager.performHiDPI(.off) }
                    } else {
                        Button(HiDPIAction.on.title) { manager.performHiDPI(.on) }.disabled(!status.supported || status.foreignOverride)
                    }
                    Text("It takes effect after a restart. Then choose a size in System Settings > Displays. Turning them off takes back only what was written here, and a chosen HiDPI size goes back to the monitor's own.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    func monitorText(_ status: HiDPIStatus) -> String {
        let parts = [status["display"], status["native"]].filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "Not found") : parts.joined(separator: "  ")
    }

    func stateText(_ status: HiDPIStatus) -> String {
        switch (status.on, status.active) {
        case (true, true): return String(localized: "On")
        case (true, false): return String(localized: "On after a restart")
        case (false, true): return String(localized: "Off after a restart")
        default: return String(localized: "Off")
        }
    }
}
