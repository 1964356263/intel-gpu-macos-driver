// SPDX-License-Identifier: MIT
// Runs the package's own scripts. The app decides nothing about what is copied where: install.sh does, so a change made in
// Terminal and one made here are the same change. EFI files are never touched.
import Foundation

/// A shell word: the whole text, quoted for /bin/sh.
func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Text for a double-quoted AppleScript string.
func appleScriptQuoted(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// The AppleScript that runs this command as root with its output in a log file: macOS asks for the password.
func privilegedScript(command: String, log: String, prompt: String) -> String {
    let shell = "/bin/bash -c \(shellQuoted(command)) >> \(shellQuoted(log)) 2>&1"
    return "do shell script \"\(appleScriptQuoted(shell))\" with prompt \"\(appleScriptQuoted(prompt))\" with administrator privileges"
}

struct RunResult {
    let succeeded: Bool
    let cancelled: Bool
    let message: String
}

/// `needsRoot`: through the macOS password dialog. Blocks: call it off the main thread.
func run(command: String, needsRoot: Bool, log: URL, prompt: String) -> RunResult {
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let process = Process()
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = Pipe()
    if needsRoot && ProcessInfo.processInfo.environment["INTELXE_MANAGER_TEST_NO_ROOT"] == nil {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", privilegedScript(command: command, log: log.path, prompt: prompt)]
    } else {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "(\(command)) >> \(shellQuoted(log.path)) 2>&1"]
    }
    do { try process.run() } catch { return RunResult(succeeded: false, cancelled: false, message: error.localizedDescription) }
    let data = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return RunResult(succeeded: process.terminationStatus == 0, cancelled: text.contains("-128"), message: text)
}

enum DriverAction: String, CaseIterable, Identifiable {
    case check, install, repair, undo, uninstall
    var id: String { rawValue }
    var argument: String {
        switch self {
        case .check: return "--check"
        case .install: return "--apply"
        case .repair: return "--repair"
        case .undo: return "--undo"
        case .uninstall: return "--uninstall"
        }
    }
    var needsRoot: Bool { self != .check }
    var needsReboot: Bool { self != .check }
}

enum ZinkAction: String, Identifiable {
    case install, undo, globalOn, globalOff, test
    var id: String { rawValue }
    var arguments: String {
        switch self {
        case .install: return ""
        case .undo: return "--undo"
        case .globalOn: return "--global on"
        case .globalOff: return "--global off"
        case .test: return "--test"
        }
    }
    var needsRoot: Bool { self != .test }
}
