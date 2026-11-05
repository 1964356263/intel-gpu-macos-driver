// SPDX-License-Identifier: MIT
// The EFI page's facts and commands. efi.sh decides what changes in the EFI (the package's copy, or the one inside this app
// for packages made before it): the app shows its plan, asks, and runs it with the plan's SHA-256, so that efi.sh writes
// nothing unless the EFI is still in the state the plan was made from.
import CryptoKit
import Foundation

/// Which EFI efi.sh works on: the one OpenCore recorded in NVRAM, a partition chosen by its UUID, or a folder that holds
/// EFI/OC (one the user chose, such as a USB stick's; the tests' fake EFI).
enum EFITarget: Hashable {
    case recorded
    case partition(String)
    case folder(String)
    var arguments: [String] {
        switch self {
        case .recorded: return []
        case .partition(let uuid): return ["--part", uuid]
        case .folder(let path): return ["--efi", path]
        }
    }
}

/// The folder to give efi.sh --efi for a folder the user picked: the picked folder when it holds EFI/OC (a USB stick, a
/// mounted partition), its parent when it is the EFI folder itself (it holds OC); nil for anything else.
func efiFolderRoot(for picked: URL) -> String? {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    func dir(_ url: URL) -> Bool { fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue }
    let url = picked.standardizedFileURL
    if dir(url.appendingPathComponent("EFI/OC")) { return url.path }
    let parent = url.deletingLastPathComponent()
    if dir(url.appendingPathComponent("OC")) && dir(parent.appendingPathComponent("EFI/OC")) { return parent.path }
    return nil
}

/// An EFI partition efi.sh found: "candidate=UUID|device|disk|size|mount point|OpenCore".
struct EFICandidate: Hashable, Identifiable {
    let uuid: String
    let device: String
    let disk: String
    let size: String
    let mountPoint: String
    let openCore: String
    var id: String { uuid }
    init?(_ text: String) {
        let fields = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6, !fields[0].isEmpty else { return nil }
        (uuid, device, disk, size, mountPoint, openCore) = (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])
    }
    var label: String { "\(disk.isEmpty ? "?" : disk), \(size) (\(device))" }
}

/// efi.sh --status.
struct EFIStatus {
    var values: [String: String] = [:]
    var candidates: [EFICandidate] = []
    init() {}
    init(text: String) {
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "candidate" {
                if let candidate = EFICandidate(pair[1]) { candidates.append(candidate) }
            } else {
                values[pair[0]] = pair[1]
            }
        }
    }
    subscript(key: String) -> String { values[key] ?? "" }
    var known: Bool { !values.isEmpty }
    var found: Bool { !["", "none"].contains(self["efi_source"]) }
    var mounted: Bool { self["efi_mounted"] == "yes" }
    var readable: Bool { self["efi_readable"] == "yes" }
    var isOpenCore: Bool { self["opencore"] == "yes" }
    var fileChanges: Int { Int(self["plan_changes"]) ?? 0 }
    var settingsChanges: Int { Int(self["settings_changes"]) ?? 0 }
    var backup: String? { ["", "none"].contains(self["backup"]) ? nil : self["backup"] }
}

/// A plan as efi.sh prints it. Its hash goes back to efi.sh with the command.
struct EFIPlan: Hashable {
    let text: String
    var hash: String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    var lines: [String] { text.split(separator: "\n").map(String.init) }
    var changes: Bool { lines.dropFirst().contains { !$0.hasPrefix("note ") && $0 != "nothing to change" } }
}

enum EFIAction: String, Identifiable {
    case mount, apply, settings, undo
    var id: String { rawValue }
    var argument: String {
        switch self {
        case .mount: return "--mount"
        case .apply: return "--apply"
        case .settings: return "--settings-apply"
        case .undo: return "--undo"
        }
    }
    var planArgument: String? {
        switch self {
        case .mount: return nil
        case .apply: return "--plan"
        case .settings: return "--settings-plan"
        case .undo: return "--undo-plan"
        }
    }
}

/// The package's efi.sh, or the copy in this app for packages made before efi.sh.
func efiScript(for package: Package) -> URL? {
    let own = package.directory.appendingPathComponent("efi.sh")
    if FileManager.default.fileExists(atPath: own.path) { return own }
    return Bundle.main.url(forResource: "efi", withExtension: "sh")
}

/// efi.sh's command line, as words.
func efiWords(script: URL, package: Package, target: EFITarget, _ argument: String) -> [String] {
    ["/bin/bash", script.path, argument, "--package", package.directory.path] + target.arguments
}

func efiStatus(script: URL, package: Package, target: EFITarget) -> EFIStatus {
    let words = efiWords(script: script, package: package, target: target, "--status")
    return EFIStatus(text: commandOutput(words[0], Array(words.dropFirst()), seconds: 90) ?? "")
}

/// A plan, or nil when efi.sh could not make one (the EFI is not mounted, not OpenCore, ...).
func efiPlan(script: URL, package: Package, target: EFITarget, _ argument: String) -> EFIPlan? {
    let words = efiWords(script: script, package: package, target: target, argument)
    guard let text = commandOutput(words[0], Array(words.dropFirst()), seconds: 90), text.hasPrefix("EFI: ") else { return nil }
    return EFIPlan(text: text)
}

/// What to say about the EFI after a driver action. Only when the EFI's IntelXe.kext is not this package's, or not on,
/// or could not be read.
enum EFINotice: Equatable {
    case kextDiffers, kextMissing, unchecked, removeKext

    static func after(_ action: DriverAction, status: EFIStatus) -> EFINotice? {
        switch action {
        case .install, .repair:
            switch status["kext_file"] {
            case "same": return ["enabled", "unknown", ""].contains(status["kext_entry"]) ? nil : .kextMissing
            case "different": return .kextDiffers
            case "absent": return .kextMissing
            default: return .unchecked
            }
        case .uninstall:
            return status["kext_entry"] == "enabled" || status["kext_entry"] == "unknown" || !status.known ? .removeKext : nil
        case .check, .undo:
            return nil
        }
    }
}
